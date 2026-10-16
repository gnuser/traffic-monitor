#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/谁在吃流量.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/traffic-monitor-swift-cache" main.swift Sites.swift -o "$APP/Contents/MacOS/TrafficMonitor" -framework Cocoa -framework SwiftUI
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrafficMonitor</string>
<key>CFBundleIdentifier</key><string>app.local.traffic-monitor</string>
<key>CFBundleName</key><string>谁在吃流量</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
"$APP/Contents/MacOS/TrafficMonitor" --self-test
printf '%s\n' "$APP"
