# 谁在吃流量 · Traffic Monitor

A small, open-source macOS network monitor: see **which apps and websites are using your bandwidth**. Built with SwiftUI and system tools, with no third-party package dependencies.

一个本地运行的 macOS 流量工具，帮助查看 **应用 → 网站 → 下载 / 上传速度**。

## 功能

- **应用 → 网站（Clash）**：复用 Clash Verge / Mihomo 的本机连接接口，每 5 秒刷新一次。
- 按应用分组，查看域名、实时下载/上传速度、活动连接累计接收和 PID。
- 默认全部收起；点击整行展开。操作后固定应用顺序，避免刷新时跳动；支持「全部收起」「重新排序」。
- 搜索应用、域名或 PID，按下载或上传速度排序。
- **所有应用（系统）**：使用 macOS 自带 `nettop`，每 2 秒采样，无需 Clash。
- 两种视图只运行各自的采集器。网站模式在隐藏或最小化窗口后暂停查询。
- 不上传数据、不修改代理配置、不抓取 HTTPS 内容。

界面目前为中文。UI is currently in Chinese.

## 从源码构建

需要 macOS 13+ 和 Xcode Command Line Tools。支持 Apple silicon / Intel，生成本机架构的应用。

```sh
git clone https://github.com/gnuser/traffic-monitor.git
cd traffic-monitor
bash build.sh
open '谁在吃流量.app'
```

构建后也可将 `.app` 拖入「应用程序」。构建脚本会运行不依赖网络的自检。当前不提供 Apple 开发者签名或公证版本。

## 网站视图如何工作

1. 从本机 Clash 的 Unix socket 读取 `/connections`。
2. 优先使用 Clash 的进程信息；缺失时用 `lsof` 的协议和源端口关联当前进程。
3. 用进程路径与父进程归并到应用；无法唯一匹配时显示「未识别应用」。

自动读取 Clash Verge 的配置位置：

```text
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml
```

使用其中的 `external-controller-unix` 路径，默认 `/tmp/verge/verge-mihomo.sock`。不使用 API 密钥，不启用新的监听端口。其他 Clash 配置路径目前需要修改 `clashSocketPath()`。

## 统计口径与限制

- 网站视图只覆盖 **经过 Clash 的当前连接**，不是浏览器标签页或完整 URL 识别。没有域名时显示 IP。
- 第一次采样建立基准，下一次才有速度；两个采样之间就关闭的短连接可能遗漏。
- 网站累计数来自当前活动连接，连接关闭后会从列表移除，不能作为长期流量账单。
- 系统视图包含本机通信；代理转发流量可能与来源应用重复，不能把所有行相加当作外网总量。
- 系统计数可能因连接结束而下降；负增量记为零，速度属于采样估计值。
- 某些系统或其他用户的进程可能不可见；工具不自动申请 root 权限。
- `nettop` 输出可能缓冲，因此系统视图会有几秒延迟。网站模式是低频本地查询，CPU 开销依连接数量和机器而异。

## CPU 回归检查

```sh
python3 check-cpu.py
```

此检查需要 Python 3，在普通终端测量 8 秒，验证采集器有有效输出且平均 CPU 不超过回归阈值。它使用实际系统统计，因此不在 CI 中运行。

macOS `nettop` 在后台收到标准输入 EOF 时可能忙循环。工具在采集期间保留打开的输入管道，并启用 `-c`；仅增加 `-c` 不能修复 EOF 问题。

## 项目结构

| 文件 | 用途 |
| --- | --- |
| `main.swift` | 系统流量采集、应用归类、应用窗口与自检入口 |
| `Sites.swift` | Clash 连接解析、端口映射、网站分组和界面 |
| `build.sh` | 构建应用并运行自检 |
| `check-cpu.py` | 实机采集 CPU 回归检查 |

欢迎提交 issue 或 PR。报告问题时请先移除真实域名、账号信息和本机路径，不要上传代理密钥或订阅配置。

## License

[Apache-2.0](LICENSE). Copyright 2026 gnuser.
