#!/usr/bin/env bash
# Compile and test protocol code without requiring the SwiftUI app toolchain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PACKAGE="$(mktemp -d "${TMPDIR:-/tmp}/osmotic-avata-core.XXXXXX")"
trap 'rm -rf "$TEST_PACKAGE"' EXIT
mkdir -p "$TEST_PACKAGE/Sources" "$TEST_PACKAGE/Tests"
ln -s "$ROOT_DIR/Sources/OsmoticCore" "$TEST_PACKAGE/Sources/OsmoticCore"
ln -s "$ROOT_DIR/Tests/OsmoticCoreTests" "$TEST_PACKAGE/Tests/OsmoticCoreTests"
cat > "$TEST_PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Osmotic",
    platforms: [.macOS(.v15)],
    products: [.library(name: "OsmoticCore", targets: ["OsmoticCore"])],
    targets: [
        .target(name: "OsmoticCore"),
        .testTarget(name: "OsmoticCoreTests", dependencies: ["OsmoticCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
SWIFT
SWIFT_FLAGS=()
SWIFT_BIN="$(xcrun --find swiftc)"
SWIFT_PREFIX="$(cd "$(dirname "$SWIFT_BIN")/.." && pwd)"
TESTING_PLUGINS="$SWIFT_PREFIX/lib/swift/host/plugins/testing"
if [ -f "$TESTING_PLUGINS/libTestingMacros.dylib" ]; then
    SWIFT_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
swift test --package-path "$TEST_PACKAGE" \
    --scratch-path "$ROOT_DIR/.build/core-tests" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} "$@"
