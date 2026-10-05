#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_PACKAGE="$(mktemp -d "${TMPDIR:-/tmp}/avata-probe.XXXXXX")"
trap 'rm -rf "$PROBE_PACKAGE"' EXIT
mkdir -p "$PROBE_PACKAGE/Sources/AvataProbe"
ln -s "$ROOT_DIR/Sources/OsmoticCore" "$PROBE_PACKAGE/Sources/OsmoticCore"
cp "$ROOT_DIR"/Sources/AvataProbe/*.swift "$PROBE_PACKAGE/Sources/AvataProbe/"
# Reuse the real app's Bluetooth and Wi-Fi implementations without its SwiftUI build target.
cp "$ROOT_DIR/Sources/Osmotic/Services/BluetoothService.swift" "$ROOT_DIR/Sources/Osmotic/Services/WiFiService.swift" "$PROBE_PACKAGE/Sources/AvataProbe/"
cat > "$PROBE_PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AvataProbe", platforms: [.macOS(.v15)], targets: [
    .target(name: "OsmoticCore"),
    .executableTarget(name: "AvataProbe", dependencies: ["OsmoticCore"], swiftSettings: [.defaultIsolation(MainActor.self)])
])
SWIFT
swift build --package-path "$PROBE_PACKAGE" --scratch-path "$ROOT_DIR/.build/probe" --product AvataProbe
BIN_DIR="$(swift build --package-path "$PROBE_PACKAGE" --scratch-path "$ROOT_DIR/.build/probe" --show-bin-path)"
APP_DIR="$ROOT_DIR/build/AvataProbe.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/AvataProbe" "$APP_DIR/Contents/MacOS/AvataProbe"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.kc3bzu.avata-probe</string>
<key>CFBundleName</key><string>AvataProbe</string><key>CFBundleDisplayName</key><string>Osmotic Avata Test</string>
<key>CFBundleExecutable</key><string>AvataProbe</string><key>CFBundlePackageType</key><string>APPL</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Pair with your Avata 2 to read its Wi-Fi credentials.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Read the current Wi-Fi network so the offline test can restore it automatically.</string>
<key>NSLocationUsageDescription</key><string>Read the current Wi-Fi network for automatic recovery.</string>
<key>NSLocalNetworkUsageDescription</key><string>Read photos and video from the aircraft's own Wi-Fi.</string>
<key>NSBonjourServices</key><array><string>_osmotic._udp</string></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf '%s\n' "$APP_DIR"
