import AppKit
import CoreWLAN
import CryptoKit
import Foundation
import OsmoticCore

nonisolated final class ProbeLog: @unchecked Sendable {
    let lock = NSLock()
    var file: URL?
    var secrets: Set<String> = []
    func write(_ message: String) {
        lock.withLock {
            var clean = message
            for secret in secrets where !secret.isEmpty { clean = clean.replacingOccurrences(of: secret, with: "<private>") }
            guard let file else { return }
            let data = Data((ISO8601DateFormatter().string(from: Date()) + " " + clean + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: file) { try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
        }
    }
    func redact(_ value: String) { lock.withLock { _ = secrets.insert(value) } }
}
let probeLog = ProbeLog()
nonisolated func log(_ message: String) { probeLog.write(message) }
nonisolated func redactedSSID(_ ssid: String) -> String { "<network>" }

@MainActor final class ProbeController: NSObject, NSApplicationDelegate {
    let ble = BluetoothService()
    let location = LocationPermission()
    let directory: URL
    let mode: String
    var window: NSWindow!
    var text: NSTextView!
    var flow: PairingFlow?
    var credentials: (String, String)?
    var cancelled = false
    var session: DroneMediaSession?
    var task: Task<Void, Never>?
    var watchdogProcess: Process?
    var displayTimer: Timer?
    var awakeActivity: NSObjectProtocol?
    var networkTask: Task<Void, Never>?
    init(directory: URL, mode: String) { self.directory = directory; self.mode = mode }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Osmotic Avata · Local Test"
        let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height];
        scroll.hasVerticalScroller = true
        text = NSTextView(frame: scroll.bounds); text.isEditable = false;
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = text; window.contentView?.addSubview(scroll)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let data = try? Data(contentsOf: self.directory.appendingPathComponent("report.log")) else {
                    return
                }
                self.text.string = String(decoding: data, as: UTF8.self)
                self.text.scrollToEndOfDocument(nil)
            }
        }
        task = Task { await run() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelled = true; flow?.cancel(); ble.stopScan(); ble.disconnect(); networkTask?.cancel(); task?.cancel()
        endAwakeActivity()
        if watchdogProcess != nil { try? Data().write(to: directory.appendingPathComponent("restore.now")) }
        return .terminateNow
    }
    func run() async {
        log("probe: starting \(mode); network changes require a ready recovery watchdog")
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Avata offline transfer test")
        defer { if networkTask == nil { endAwakeActivity() } }
        WiFiService.allowNetworksetupJoin = false
        LocalNetworkPermission.prime()
        let suppliedHome = try? String(
            contentsOfFile: argument("--return-network-file", fallback: "/nonexistent"), encoding: .utf8)
        if suppliedHome == nil || mode != "recovery-test" { await location.request() }
        guard !cancelled else { return }
        let home = WiFiService.currentSSID() ?? suppliedHome
        if let home { probeLog.redact(home) }
        let interface = WiFiService.interfaceName ?? "en0"
        let saved = home == nil ? false : await WiFiService.isSavedNetwork(home!)
        log("preflight: return network readable=\(home != nil), saved=\(saved), interface=\(interface)")
        if mode == "recovery-test" {
            guard let home, saved else {
                log("preflight: stopped; Location permission and a saved return network are required"); return
            }
            await startWatchdog(home: home, interface: interface, seconds: 3, testOnly: false)
            log("recovery test: waiting for independent watchdog to terminate this runner")
            return
        }
        let proofURL = URL(fileURLWithPath: argument("--recovery-proof-file", fallback: "/nonexistent"))
        let proof = (try? Data(contentsOf: proofURL)).flatMap { try? JSONDecoder().decode(OfflineRecoveryProof.self, from: $0) }
        let executableHash =
            (try? Data(contentsOf: Bundle.main.executableURL!)).map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            } ?? ""
        if mode == "live"
            && !OfflineRecoveryPolicy.canJoin(home: home, saved: saved, proof: proof, executable: executableHash, now: Date())
        {
            log("preflight: stopped; a successful recent recovery test for this build and return network is required"); return
        }
        ble.startScan()
        let permissionDeadline = Date().addingTimeInterval(120)
        while ble.power == .unknown && Date() < permissionDeadline && !cancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard ble.power == .poweredOn else { ble.stopScan(); log("BLE: Bluetooth unavailable or permission denied"); return }
        let scanDeadline = Date().addingTimeInterval(20)
        while ble.sortedCameras.first(where: { $0.modelId == 0x77 }) == nil && Date() < scanDeadline && !cancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let drone = ble.sortedCameras.first(where: { $0.modelId == 0x77 }), !cancelled else {
            ble.stopScan(); log("BLE: no Avata 2 found; stopped without switching Wi-Fi"); return
        }
        ble.stopScan(); probeLog.redact(drone.name)
        let identity = PairingIdentity.load(from: .standard)
        let f = PairingFlow(bleName: drone.name, savedPassword: nil, identifier: identity, token: drone.model.pairingToken)
        flow = f; f.log = { log($0) }; f.write = { [weak self] in self?.ble.write($0) }
        f.schedule = { delay, body in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay)); body()
            }
        }
        f.emit = { [weak self] event in
            guard let self else { return }
            switch event {
            case .approvalRequired: log("ACTION: hold the Avata power button for two seconds to approve pairing")
            case .paired: log("pairing: approved")
            case .credentials(let ssid, let password):
                probeLog.redact(ssid); probeLog.redact(password); self.credentials = (ssid, password);
                log("pairing: received Wi-Fi credentials")
            case .needsPassword: log("pairing: aircraft did not supply a password; stopped")
            case .notActivated: log("pairing: aircraft reports it is not activated")
            }
        }
        ble.onReady = { [weak f] in f?.onReady() }
        ble.onMessage = { [weak f] in f?.onMessage($0) }
        guard ble.connect(drone.id) else { log("BLE: connect failed"); return }
        let deadline = Date().addingTimeInterval(70)
        while credentials == nil && Date() < deadline && !cancelled { try? await Task.sleep(for: .milliseconds(200)) }
        guard let (ssid, password) = credentials, !cancelled else {
            f.cancel(); ble.disconnect(); log("pairing: no credentials; stopped without switching Wi-Fi"); return
        }
        if mode != "live" { log("pair-only test complete; Wi-Fi unchanged"); f.cancel(); ble.disconnect(); return }
        guard let home, saved, home != ssid else { log("preflight: no distinct saved return network"); return }
        let forgetCamera = !(await WiFiService.isSavedNetwork(ssid))
        let recoveryReady = await startWatchdog(
            home: home, interface: interface, seconds: 120, testOnly: false,
            cameraSSID: ssid, forgetCamera: forgetCamera)
        guard recoveryReady else { log("preflight: watchdog did not acknowledge readiness; stopped"); return }
        log("offline: 120-second budget armed; joining aircraft network")
        networkTask = Task {
            do {
                let joined = try await WiFiService.join(ssid: ssid, password: password, timeout: 35) { _ in
                    log("wifi: waiting for aircraft network")
                }
                try Task.checkCancellation()
                let s = DroneMediaSession(
                    model: drone.model, interfaceName: joined.interface, identity: identity, deviceIdentity: drone.id.uuidString,
                    log: { log($0) })
                session = s
                log("drone: negotiating media session")
                let result: CameraSession.ConnectResult
                if arguments.contains("--probe-existing-media") {
                    result = await s.probeExistingMediaList()
                } else {
                    result = await s.connect()
                }
                if result.handshakeOk {
                    log("library: \(result.files.count) files, more=\(result.moreAvailable)")
                    let http = CameraHTTP(); let dl = FileDownloader(http: http, log: { log($0) })
                    let candidates = [
                        result.files.filter(\.isImage).min(by: { $0.sizeBytes < $1.sizeBytes }),
                        result.files.filter(\.isVideo).min(by: { $0.sizeBytes < $1.sizeBytes }),
                    ].compactMap { $0 }
                    for file in candidates {
                        try Task.checkCancellation()
                        let dest = directory.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(
                            file.localName)
                        log("download: beginning \(file.name), listed bytes=\(file.sizeBytes)")
                        let r = await dl.download(
                            urlPath: file.originalURLPath, to: dest, expectedSize: file.sizeBytes,
                            identity: file.downloadIdentity,
                            onTotal: { log("download: server bytes=\($0)") }, progress: { _ in })
                        if case .saved(let url) = r {
                            let (_, hash) = command("/usr/bin/shasum", ["-a", "256", url.path])
                            log("download: saved \(file.name), SHA256=\(hash.split(separator: " ").first ?? "unknown")")
                        } else {
                            log("download: \(r)")
                        }
                    }
                } else {
                    log("drone: session failed: \(s.failureDescription ?? "unknown")")
                }
                await s.close()
            } catch { log("offline: test ended: \(error.localizedDescription)") }
            flow?.cancel(); ble.disconnect()
            endAwakeActivity()
            log("offline: finished; independent watchdog restoring internet")
            try? Data().write(to: directory.appendingPathComponent("restore.now"))
        }
    }
    func endAwakeActivity() {
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
    }
    func startWatchdog(
        home: String, interface: String, seconds: Double, testOnly: Bool, cameraSSID: String? = nil, forgetCamera: Bool = false
    ) async -> Bool {
        let bundle = Bundle.main.bundleURL.path
        guard let launched = NSRunningApplication.current.launchDate else { return false }
        let lease = RecoveryLease(
            pid: getpid(), launchDate: launched, bundlePath: bundle, homeSSID: home, interface: interface,
            deadline: Date().addingTimeInterval(seconds), testOnly: testOnly, cameraSSID: cameraSSID, forgetCamera: forgetCamera)
        do {
            for name in ["watchdog.ready", "restore.now", "recovery.status"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            let url = directory.appendingPathComponent("lease.json")
            try JSONEncoder().encode(lease).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let p = Process(); p.executableURL = Bundle.main.executableURL
            p.arguments = ["--watchdog", directory.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); watchdogProcess = p
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("watchdog.ready").path) { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch { log("preflight: unable to start watchdog") }
        return false
    }
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--rejoin-home"), arguments.count > i + 1 {
    exit(rejoinHome(URL(fileURLWithPath: arguments[i + 1])))
}
if let i = arguments.firstIndex(of: "--watchdog"), arguments.count > i + 1 {
    watchdog(URL(fileURLWithPath: arguments[i + 1])); exit(0)
}
func argument(_ name: String, fallback: String) -> String {
    if let i = arguments.firstIndex(of: name), arguments.count > i + 1 { return arguments[i + 1] }; return fallback
}
let directory = URL(
    fileURLWithPath: argument("--run-directory", fallback: NSTemporaryDirectory() + "AvataProbe-" + UUID().uuidString))
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let report = directory.appendingPathComponent("report.log")
FileManager.default.createFile(atPath: report.path, contents: nil, attributes: [.posixPermissions: 0o600])
probeLog.file = report
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = ProbeController(directory: directory, mode: argument("--mode", fallback: "pair"))
app.delegate = controller
app.run()
