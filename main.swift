import Cocoa
import SwiftUI

struct Counter: Equatable {
    var name: String
    var pid: Int
    var received: Double
    var sent: Double
}

// nettop emits a CSV header before every snapshot. Names may contain periods.
func parseCounter(_ line: String) -> Counter? {
    let fields = line.split(separator: ",", omittingEmptySubsequences: false)
    guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
          let pid = Int(fields[0][fields[0].index(after: dot)...]),
          let received = Double(fields[1]), let sent = Double(fields[2]),
          received.isFinite, sent.isFinite, received >= 0, sent >= 0 else { return nil }
    return Counter(name: String(fields[0][..<dot]), pid: pid, received: received, sent: sent)
}
func rate(_ current: Double, _ previous: Double, _ elapsed: Double) -> Double {
    guard elapsed > 0 else { return 0 }
    return max(0, current - previous) / elapsed
}
func amount(_ value: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var number = value
    var index = 0
    while number >= 1024 && index < units.count - 1 { number /= 1024; index += 1 }
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", number, units[index])
}
struct ProcessInfoRow {
    var parent: Int
    var command: String
}
func appName(pid: Int, fallback: String, processes: [Int: ProcessInfoRow]) -> String {
    var cursor = pid
    var visited = Set<Int>()
    for _ in 0..<12 {
        guard visited.insert(cursor).inserted, let entry = processes[cursor] else { break }
        if let range = entry.command.range(of: ".app/") {
            return URL(fileURLWithPath: String(entry.command[..<range.lowerBound])).lastPathComponent
        }
        cursor = entry.parent
    }
    return fallback
}
struct TrafficRow: Identifiable {
    var id: String { name }
    var name: String
    var download = 0.0
    var upload = 0.0
    var received = 0.0
    var sent = 0.0
    var processes: [String] = []
    var proxy: Bool {
        let lower = name.lowercased()
        return ["clash", "mihomo", "surge", "sing-box", "v2ray", "xray"].contains { lower.contains($0) }
    }
}

// Keeps framing independent of pipe chunk boundaries.
final class SnapshotDecoder {
    private var buffer = Data()
    private var current: [Counter] = []
    func consume(_ data: Data) -> [[Counter]] {
        buffer.append(data)
        var snapshots: [[Counter]] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            if line.contains("bytes_in") && line.contains("bytes_out") {
                if !current.isEmpty { snapshots.append(current) }
                current = []
            } else if let counter = parseCounter(line) { current.append(counter) }
        }
        return snapshots
    }
}

final class Monitor: ObservableObject {
    @Published var rows: [TrafficRow] = []
    @Published var status = "正在启动…"
    @Published var active = false
    @Published var sampled = false
    private var process: Process?
    // nettop watches stdin even in logging mode. EOF causes a busy loop.
    // Keep both ends alive until the collector is stopped.
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var previous: [Int: Counter] = [:]
    private var lastTime: TimeInterval?
    private var processMap: [Int: ProcessInfoRow] = [:]
    private var lastMapUpdate = 0.0
    private var generation = UUID()

    func start() {
        guard process == nil else { return }
        previous = [:]; lastTime = nil; rows = []; sampled = false
        let generation = UUID()
        self.generation = generation
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let decoder = SnapshotDecoder()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-n", "-x", "-c", "-L", "0", "-s", "2", "-J", "bytes_in,bytes_out"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let snapshots = decoder.consume(data)
            for snapshot in snapshots {
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.update(snapshot)
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.status = "无法读取流量：\(message)"
            }
        }
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.active = false
                self.process = nil
                self.input = nil
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.errors?.fileHandleForReading.readabilityHandler = nil
                if task.terminationStatus != 0 && !self.status.hasPrefix("无法") {
                    self.status = "采集进程已退出（\(task.terminationStatus)）。请重试。"
                }
            }
        }
        self.process = process; self.input = input; self.output = output; self.errors = errors
        do {
            try process.run()
            active = true
            status = "正在采样，首次结果可能需要约 10 秒…"
        } catch {
            stop()
            status = "无法启动：\(error.localizedDescription)"
        }
    }
    func stop() {
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; errors = nil
        active = false
        status = "已暂停 · 显示的是暂停前的采样"
    }
    private func refreshProcesses() {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,comm="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return }
        var map: [Int: ProcessInfoRow] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) {
                map[pid] = ProcessInfoRow(parent: parent, command: String(fields[2]))
            }
        }
        processMap = map
    }
    private func update(_ counters: [Counter]) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMapUpdate >= 10 { refreshProcesses(); lastMapUpdate = now }
        // Pipe output may deliver multiple snapshots together. Use nettop’s
        // sampling interval, never the interval between pipe callbacks.
        let elapsed = lastTime == nil ? 0.0 : 2.0
        var groups: [String: TrafficRow] = [:]
        for counter in counters {
            let name = appName(pid: counter.pid, fallback: counter.name, processes: processMap)
            var row = groups[name] ?? TrafficRow(name: name)
            if let old = previous[counter.pid], old.name == counter.name {
                row.download += rate(counter.received, old.received, elapsed)
                row.upload += rate(counter.sent, old.sent, elapsed)
            }
            row.received += counter.received
            row.sent += counter.sent
            row.processes.append("\(counter.name) · PID \(counter.pid)")
            groups[name] = row
        }
        rows = Array(groups.values)
        previous = Dictionary(counters.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        sampled = lastTime != nil
        lastTime = now
        status = sampled ? "每 2 秒采样 · \(counters.count) 个进程 · \(groups.count) 个应用 / 服务" : "已取得基准，正在计算速度…"
    }
}

struct AppTrafficView: View {
    @ObservedObject var monitor: Monitor
    @State private var search = ""
    @State private var sortUpload = false
    @State private var showIdle = false
    var filtered: [TrafficRow] {
        monitor.rows.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.processes.contains { $0.localizedCaseInsensitiveContains(search) }) &&
            (showIdle || $0.download > 0 || $0.upload > 0)
        }.sorted {
            let a = sortUpload ? $0.upload : $0.download
            let b = sortUpload ? $1.upload : $1.download
            return a == b ? $0.name < $1.name : a > b
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("谁在吃流量").font(.system(size: 28, weight: .bold))
                    Text(monitor.status).foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                }
                Spacer()
                Button(monitor.active ? "暂停采集" : "开始采集") {
                    if monitor.active { monitor.stop() } else { monitor.start() }
                }.controlSize(.large)
            }
            HStack(spacing: 16) {
                TextField("搜索应用名称或 PID", text: $search).textFieldStyle(.roundedBorder)
                Picker("排序", selection: $sortUpload) {
                    Text("下载最多").tag(false)
                    Text("上传最多").tag(true)
                }.frame(width: 180)
                Toggle("显示空闲", isOn: $showIdle)
            }
            HStack {
                Text("应用 / 进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("↓ 下载 / 秒").frame(width: 110, alignment: .trailing)
                Text("↑ 上传 / 秒").frame(width: 110, alignment: .trailing)
                Text("累计接收").frame(width: 100, alignment: .trailing)
                Text("累计发送").frame(width: 100, alignment: .trailing)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { row in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(row.processes.sorted(), id: \.self) { process in
                                    Text(process).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                if row.proxy { Text("代理转发流量可能已在来源应用中计数，请勿相加。").foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        } label: {
                            HStack {
                                HStack(spacing: 8) {
                                    Image(systemName: row.proxy ? "arrow.triangle.branch" : "app.fill").foregroundStyle(row.proxy ? Color.orange : Color.accentColor)
                                    Text(row.name).fontWeight(.medium).lineLimit(1)
                                    if row.proxy { Text("代理").font(.caption2).foregroundStyle(.orange) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(amount(row.download)).foregroundStyle(.blue).frame(width: 110, alignment: .trailing)
                                Text(amount(row.upload)).foregroundStyle(.green).frame(width: 110, alignment: .trailing)
                                Text(amount(row.received)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                                Text(amount(row.sent)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                            }.monospacedDigit().padding(.vertical, 8)
                        }.padding(.horizontal, 12).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if filtered.isEmpty {
                        Text(monitor.sampled ? "当前没有匹配的活跃应用，可勾选「显示空闲」。" : "正在等待采样…")
                            .foregroundStyle(.secondary).padding(40)
                    }
                }
            }
            Text("速度来自系统网络计数，包含本机通信；累计值为系统当前保留的进程连接计数，并非本次打开以来的用量。展开应用可查看 PID。所有数据仅在本机读取。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(minWidth: 900, minHeight: 540)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let sites = SitesMonitor()
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "谁在吃流量"
        window.contentView = NSHostingView(rootView: ContentView(monitor: monitor, sites: sites))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop(); sites.stop() }
}

if CommandLine.arguments.contains("--self-test") {
    assert(parseCounter("Codex (Service).44249,1000,300,") == Counter(name: "Codex (Service)", pid: 44249, received: 1000, sent: 300))
    assert(parseCounter("python3.13.536,5,9,")?.pid == 536)
    assert(parseCounter(",bytes_in,bytes_out,") == nil)
    assert(parseCounter("bad.3,NaN,0,") == nil)
    assert(rate(2000, 1000, 2) == 500)
    assert(rate(0, 1000, 2) == 0)
    assert(rate(2000, 1000, 0) == 0)
    let decoder = SnapshotDecoder()
    assert(decoder.consume(Data(",bytes_in,bytes_out,\nCodex (Ser".utf8)).isEmpty)
    let samples = decoder.consume(Data("vice).44249,1000,300,\n,bytes_in,bytes_out,\n".utf8))
    assert(samples.count == 1 && samples[0].first?.pid == 44249)
    assert(appName(pid: 2, fallback: "helper", processes: [2: ProcessInfoRow(parent: 1, command: "/bin/helper"), 1: ProcessInfoRow(parent: 0, command: "/Applications/My App.app/Contents/MacOS/Main")]) == "My App")
    assert(appName(pid: 2, fallback: "helper", processes: [2: ProcessInfoRow(parent: 2, command: "/bin/helper")]) == "helper")
    try testSites()
    print("PASS: parsing, partial snapshots, counter reset, rates, application grouping, parent cycle")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
