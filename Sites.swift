import Cocoa
import SwiftUI

struct ClashSnapshot: Decodable { let connections: [ClashConnection]? }
struct ClashConnection: Decodable {
    let id: String
    let download: Double
    let upload: Double
    let metadata: Metadata
    struct Metadata: Decodable {
        let network: String?
        let sourcePort: String?
        let host: String?
        let sniffHost: String?
        let destinationIP: String?
        let process: String?
        let processPath: String?
    }
}
struct SocketOwner: Hashable { let pid: Int; let name: String }
func socketOwners(_ text: String) -> [String: Set<SocketOwner>] {
    var pid = 0, name = "", network = ""
    var result: [String: Set<SocketOwner>] = [:]
    for line in text.split(separator: "\n") {
        let value = String(line.dropFirst())
        switch line.first {
        case "p": pid = Int(value) ?? 0; name = ""; network = ""
        case "c": name = value
        case "f": network = ""
        case "P": network = value.lowercased()
        case "n":
            let local = value.components(separatedBy: "->")[0]
            if let port = local.split(separator: ":").last, Int(port) != nil, pid > 0, !network.isEmpty {
                result["\(network):\(port)", default: []].insert(SocketOwner(pid: pid, name: name))
            }
        default: break
        }
    }
    return result
}
struct SiteRow: Identifiable {
    var id: String { domain }
    let domain: String
    var download = 0.0, upload = 0.0, received = 0.0, sent = 0.0
    var count = 0
    var processes = Set<String>()
}
struct SiteApp: Identifiable {
    var id: String { name }
    let name: String
    var sites: [SiteRow]
    var download: Double { sites.reduce(0) { $0 + $1.download } }
    var upload: Double { sites.reduce(0) { $0 + $1.upload } }
}
func siteGroups(_ connections: [ClashConnection], previous: [String: ClashConnection], elapsed: Double,
                owners: [String: Set<SocketOwner>], processes: [Int: ProcessInfoRow]) -> [SiteApp] {
    var groups: [String: [String: SiteRow]] = [:]
    for c in connections {
        let m = c.metadata
        let candidates = owners["\((m.network ?? "tcp").lowercased()):\(m.sourcePort ?? "")"] ?? []
        var app = "未识别应用", label = "无法匹配进程"
        if let path = m.processPath, !path.isEmpty {
            if let range = path.range(of: ".app/") { app = URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent }
            else { app = URL(fileURLWithPath: path).lastPathComponent }
            label = m.process ?? app
        } else if candidates.count == 1, let owner = candidates.first {
            app = appName(pid: owner.pid, fallback: owner.name, processes: processes)
            label = "\(owner.name) · PID \(owner.pid)"
        } else if let process = m.process, !process.isEmpty { app = process; label = process }
        let domain = [m.host, m.sniffHost, m.destinationIP].compactMap { $0 }.first { !$0.isEmpty } ?? "未知目标"
        var row = groups[app]?[domain] ?? SiteRow(domain: domain)
        if let old = previous[c.id] {
            row.download += rate(c.download, old.download, elapsed)
            row.upload += rate(c.upload, old.upload, elapsed)
        }
        row.received += max(0, c.download); row.sent += max(0, c.upload); row.count += 1
        row.processes.insert(label)
        groups[app, default: [:]][domain] = row
    }
    return groups.map { SiteApp(name: $0.key, sites: Array($0.value.values)) }
}

func runLocal(_ executable: String, _ arguments: [String]) throws -> Data {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    try task.run()
    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: timeout)
    defer { timeout.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw NSError(domain: "LocalCollector", code: Int(task.terminationStatus)) }
    return data
}
func readProcessMap() -> [Int: ProcessInfoRow] {
    guard let data = try? runLocal("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return [:] }
    var result: [Int: ProcessInfoRow] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let f = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
        if f.count == 3, let pid = Int(f[0]), let parent = Int(f[1]) { result[pid] = ProcessInfoRow(parent: parent, command: String(f[2])) }
    }
    return result
}
func clashSocketPath() -> String {
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml")
    if let text = try? String(contentsOf: config, encoding: .utf8),
       let line = text.split(separator: "\n").first(where: { $0.hasPrefix("external-controller-unix:") }) {
        let value = line.dropFirst("external-controller-unix:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.hasPrefix("/") { return value }
    }
    return "/tmp/verge/verge-mihomo.sock"
}
final class SitesMonitor: ObservableObject {
    @Published var apps: [SiteApp] = []
    @Published var status = "等待连接本机 Clash…"
    @Published var active = false
    private let queue = DispatchQueue(label: "traffic.sites", qos: .utility)
    private var timer: DispatchWorkItem?
    private var generation = UUID()
    private var previous: [String: ClashConnection] = [:]
    private var lastTime: TimeInterval?
    func start() {
        guard !active else { return }
        generation = UUID(); previous = [:]; lastTime = nil; active = true
        status = "正在读取本机 Clash 连接…"
        fetch(generation)
    }
    func stop() {
        active = false; generation = UUID(); timer?.cancel(); timer = nil
        status = "已暂停 · 显示暂停前的数据"
    }
    private func schedule(_ token: UUID, delay: Double) {
        guard active, generation == token else { return }
        let timer = DispatchWorkItem { [weak self] in self?.fetch(token) }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }
    private func fetch(_ token: UUID) {
        guard active, generation == token else { return }
        if NSApp.isHidden || (!NSApp.windows.isEmpty && NSApp.windows.allSatisfy { $0.isMiniaturized || !$0.isVisible }) {
            schedule(token, delay: 5); return
        }
        queue.async { [weak self] in
            do {
                let data = try runLocal("/usr/bin/curl", ["--silent", "--fail", "--max-time", "3", "--noproxy", "*", "--unix-socket", clashSocketPath(), "http://localhost/connections"])
                let connections = try JSONDecoder().decode(ClashSnapshot.self, from: data).connections ?? []
                let at = ProcessInfo.processInfo.systemUptime
                let sockets = (try? runLocal("/usr/sbin/lsof", ["-nP", "-i", "-FpcPn"])) ?? Data()
                let owners = socketOwners(String(decoding: sockets, as: UTF8.self))
                let processes = readProcessMap()
                DispatchQueue.main.async {
                    guard let self, self.active, self.generation == token else { return }
                    self.apps = siteGroups(connections, previous: self.previous, elapsed: self.lastTime.map { at - $0 } ?? 0, owners: owners, processes: processes)
                    self.previous = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                    self.lastTime = at
                    self.status = "本机 Clash · \(connections.count) 条活动连接 · 每 5 秒刷新"
                    self.schedule(token, delay: 5)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.active, self.generation == token else { return }
                    self.apps = []; self.previous = [:]; self.lastTime = nil
                    self.status = "无法读取本机 Clash。请确认 Clash Verge 正在运行；10 秒后重试。"
                    self.schedule(token, delay: 10)
                }
            }
        }
    }
}
struct SitesView: View {
    @ObservedObject var monitor: SitesMonitor
    @State private var search = ""
    @State private var upload = false
    @State private var expanded = Set<String>()
    @State private var lockedOrder: [String]?
    var ranked: [SiteApp] {
        monitor.apps.compactMap { app in
            let sites = app.sites.filter { search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || $0.domain.localizedCaseInsensitiveContains(search) || $0.processes.contains { $0.localizedCaseInsensitiveContains(search) } }
                .sorted { a, b in
                    let x = upload ? a.upload : a.download, y = upload ? b.upload : b.download
                    return x == y ? a.domain < b.domain : x > y
                }
            return sites.isEmpty ? nil : SiteApp(name: app.name, sites: sites)
        }.sorted { a, b in
            let x = upload ? a.upload : a.download, y = upload ? b.upload : b.download
            return x == y ? a.name < b.name : x > y
        }
    }
    var filtered: [SiteApp] {
        guard let lockedOrder else { return ranked }
        let positions = Dictionary(uniqueKeysWithValues: lockedOrder.enumerated().map { ($0.element, $0.offset) })
        return ranked.sorted {
            let a = positions[$0.id] ?? Int.max, b = positions[$1.id] ?? Int.max
            return a == b ? $0.name < $1.name : a < b
        }
    }
    func toggle(_ name: String) {
        if lockedOrder == nil { lockedOrder = ranked.map(\.id) }
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("哪些网站在吃流量").font(.system(size: 27, weight: .bold))
                    Text(monitor.status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(monitor.active ? "暂停采集" : "开始采集") { if monitor.active { monitor.stop() } else { monitor.start() } }.controlSize(.large)
            }
            HStack {
                TextField("搜索应用、网站域名或 PID", text: $search).textFieldStyle(.roundedBorder)
                Picker("排序", selection: $upload) { Text("下载最多").tag(false); Text("上传最多").tag(true) }.frame(width: 180)
                Button("重新排序") { lockedOrder = ranked.map(\.id) }
                Button("全部收起") { expanded.removeAll() }.disabled(expanded.isEmpty)
            }
            HStack {
                Text("应用 / 网站").frame(maxWidth: .infinity, alignment: .leading)
                Text("↓ 下载 / 秒").frame(width: 100, alignment: .trailing)
                Text("↑ 上传 / 秒").frame(width: 100, alignment: .trailing)
                Text("连接累计接收").frame(width: 115, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filtered) { app in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { toggle(app.id) } label: {
                              HStack {
                                Image(systemName: expanded.contains(app.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold)).frame(width: 14)
                                Label(app.name, systemImage: "app.fill").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                Text(amount(app.download)).foregroundStyle(.blue).frame(width: 100, alignment: .trailing)
                                Text(amount(app.upload)).foregroundStyle(.green).frame(width: 100, alignment: .trailing)
                                Text(amount(app.sites.reduce(0) { $0 + $1.received })).foregroundStyle(.secondary).frame(width: 115, alignment: .trailing)
                              }.contentShape(Rectangle()).padding(.vertical, 5)
                            }.buttonStyle(.plain)
                            .accessibilityLabel("\(expanded.contains(app.id) ? "收起" : "展开") \(app.name)")
                            if expanded.contains(app.id) {
                            ForEach(app.sites) { site in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(site.domain).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(amount(site.download)).foregroundStyle(.blue).frame(width: 100, alignment: .trailing)
                                        Text(amount(site.upload)).foregroundStyle(.green).frame(width: 100, alignment: .trailing)
                                        Text(amount(site.received)).foregroundStyle(.secondary).frame(width: 115, alignment: .trailing)
                                    }
                                    Text("\(site.count) 条连接 · " + site.processes.sorted().joined(separator: "，")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }.padding(.leading, 24).padding(.vertical, 3)
                            }
                            }
                        }.monospacedDigit().padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if filtered.isEmpty { Text("暂无匹配的连接；首次采样建立基准，下一次显示速度。").foregroundStyle(.secondary).padding(30) }
                }
            }
            Text("仅显示经过 Clash 的当前连接；速度按相邻采样计算，短暂连接可能遗漏。无域名时显示 IP，无法可靠匹配进程时显示「未识别应用」。累计值不含已关闭连接。隐藏或最小化窗口后暂停查询。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(minWidth: 900, minHeight: 540)
        .transaction { $0.animation = nil }
        .onChange(of: upload) { _ in lockedOrder = ranked.map(\.id) }
    }
}
struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var sites: SitesMonitor
    @State private var websites = true
    var body: some View {
        VStack(spacing: 0) {
            Picker("查看范围", selection: $websites) {
                Text("应用 → 网站（Clash）").tag(true)
                Text("所有应用（系统）").tag(false)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 14)
            if websites { SitesView(monitor: sites) } else { AppTrafficView(monitor: monitor) }
        }.onAppear { sites.start() }.onChange(of: websites) { value in
            if value { monitor.stop(); sites.start() } else { sites.stop(); monitor.start() }
        }
    }
}
func testSites() throws {
    let data = Data(#"{"connections":[{"id":"a","download":500,"upload":100,"metadata":{"network":"tcp","sourcePort":"1234","host":"example.com"}}]}"#.utf8)
    let cs = try JSONDecoder().decode(ClashSnapshot.self, from: data).connections!
    let owners = socketOwners("p7\ncBrowser\nf3\nPTCP\nn127.0.0.1:1234->127.0.0.1:7897\n")
    var rows = siteGroups(cs, previous: [:], elapsed: 5, owners: owners, processes: [:])
    assert(rows[0].name == "Browser" && rows[0].sites[0].domain == "example.com" && rows[0].download == 0)
    let old = ClashConnection(id: "a", download: 100, upload: 50, metadata: cs[0].metadata)
    rows = siteGroups(cs, previous: ["a": old], elapsed: 5, owners: owners, processes: [:])
    assert(rows[0].download == 80 && rows[0].upload == 10)
    rows = siteGroups(cs, previous: [:], elapsed: 5, owners: ["tcp:1234": [SocketOwner(pid: 7, name: "A"), SocketOwner(pid: 8, name: "B")]], processes: [:])
    assert(rows[0].name == "未识别应用")
    assert(siteGroups([], previous: ["a": old], elapsed: 5, owners: owners, processes: [:]).isEmpty)
    print("PASS: Clash JSON, domain grouping, socket mapping, first sample, rates, ambiguous owners, closed connections")
}
