import AppKit
import CoreWLAN
import CryptoKit
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
    var cameraSSID: String? = nil
    var forgetCamera = false
}

nonisolated func watchdog(_ directory: URL) {
    let fm = FileManager.default
    let leaseURL = directory.appendingPathComponent("lease.json")
    guard let data = try? Data(contentsOf: leaseURL), let lease = try? JSONDecoder().decode(RecoveryLease.self, from: data) else {
        exit(2)
    }
    // A watchdog must acknowledge readiness before its parent can change networks.
    try? Data("ready".utf8).write(to: directory.appendingPathComponent("watchdog.ready"), options: .atomic)
    while !OfflineRecoveryPolicy.shouldRestore(
        now: Date(), deadline: lease.deadline, ownerAlive: kill(lease.pid, 0) == 0,
        requested: fm.fileExists(atPath: directory.appendingPathComponent("restore.now").path))
    {
        Thread.sleep(forTimeInterval: 0.25)
    }
    // Match both bundle and launch date. A reused PID must never be killed.
    if let app = NSRunningApplication(processIdentifier: lease.pid),
        app.bundleURL?.path == lease.bundlePath,
        let launched = app.launchDate,
        OfflineRecoveryPolicy.matchesOwner(
            expectedPID: lease.pid, expectedLaunch: lease.launchDate, expectedPath: lease.bundlePath,
            pid: app.processIdentifier, launch: launched, path: app.bundleURL!.path)
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
        for _ in 0..<1 {
            let (status, _) = command(Bundle.main.executableURL!.path, ["--rejoin-home", directory.path], timeout: 40)
            if status == 0 {
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 1)
                    let (internet, _) = command(
                        "/usr/bin/curl",
                        [
                            "--interface", lease.interface, "--silent", "--fail", "--head", "--max-time", "4",
                            "https://api.github.com",
                        ], timeout: 5)
                    if internet == 0 { restored = true; break }
                }
            }
            if restored { break }
        }
    }
    if !restored {
        // Cancel any outstanding association and let macOS use its own saved network credentials.
        // Forget only the aircraft network introduced by this run, never an existing user network.
        if lease.forgetCamera, let camera = lease.cameraSSID {
            _ = command("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", lease.interface, camera])
        }
        let (off, _) = command("/usr/sbin/networksetup", ["-setairportpower", lease.interface, "off"])
        Thread.sleep(forTimeInterval: 1)
        let (on, _) = command("/usr/sbin/networksetup", ["-setairportpower", lease.interface, "on"])
        if off == 0 && on == 0 {
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 1)
                let (internet, _) = command(
                    "/usr/bin/curl",
                    [
                        "--interface", lease.interface, "--silent", "--fail", "--head", "--max-time", "4",
                        "https://api.github.com",
                    ], timeout: 5)
                if internet == 0 { restored = true; break }
            }
        }
    }
    if restored, !lease.testOnly, let executable = Bundle.main.executableURL,
        let bytes = try? Data(contentsOf: executable)
    {
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let proof = OfflineRecoveryProof(network: lease.homeSSID, executable: hash, verifiedAt: Date())
        if let data = try? JSONEncoder().encode(proof) {
            let path = directory.appendingPathComponent("recovery.proof")
            try? data.write(to: path, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    try? Data((restored ? "restored" : "restore-failed").utf8).write(
        to: directory.appendingPathComponent("recovery.status"), options: .atomic)
    // Do not retain even the home SSID after recovery.
    try? fm.removeItem(at: leaseURL)
}
