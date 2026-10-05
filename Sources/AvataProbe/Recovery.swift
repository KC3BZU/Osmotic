import AppKit
import Darwin
import Foundation
import OsmoticCore

/// Short commands run with a deadline. Output is bounded by these specific macOS tools.
nonisolated func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 12) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "could not launch") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning {
        p.terminate(); Thread.sleep(forTimeInterval: 0.1)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

nonisolated struct RecoveryLease: Codable, Sendable {
    let pid: Int32
    let launchDate: Date
    let bundlePath: String
    let homeSSID: String
    let interface: String
    let deadline: Date
    let testOnly: Bool
}

nonisolated func watchdog(_ directory: URL) {
    let fm = FileManager.default
    let leaseURL = directory.appendingPathComponent("lease.json")
    guard let data = try? Data(contentsOf: leaseURL), let lease = try? JSONDecoder().decode(RecoveryLease.self, from: data) else {
        exit(2)
    }
    // A watchdog must acknowledge readiness before its parent can change networks.
    try? Data("ready".utf8).write(to: directory.appendingPathComponent("watchdog.ready"), options: .atomic)
    while Date() < lease.deadline && !fm.fileExists(atPath: directory.appendingPathComponent("restore.now").path) {
        if kill(lease.pid, 0) != 0 { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    // Match both bundle and launch date. A reused PID must never be killed.
    if let app = NSRunningApplication(processIdentifier: lease.pid),
        app.bundleURL?.path == lease.bundlePath,
        let launched = app.launchDate, abs(launched.timeIntervalSince(lease.launchDate)) < 1
    {
        kill(lease.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while kill(lease.pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if let current = NSRunningApplication(processIdentifier: lease.pid),
            current.bundleURL?.path == lease.bundlePath,
            current.launchDate == launched
        {
            kill(lease.pid, SIGKILL)
        }
    }
    var restored = lease.testOnly
    if !lease.testOnly {
        for _ in 0..<3 {
            let (status, _) = command("/usr/sbin/networksetup", ["-setairportnetwork", lease.interface, lease.homeSSID])
            if status == 0 {
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 1)
                    if TCPProbe.connect(ip: "1.1.1.1", port: 443, timeout: 1) { restored = true; break }
                }
            }
            if restored { break }
        }
    }
    try? Data((restored ? "restored" : "restore-failed").utf8).write(
        to: directory.appendingPathComponent("recovery.status"), options: .atomic)
    // Do not retain even the home SSID after recovery.
    try? fm.removeItem(at: leaseURL)
}
