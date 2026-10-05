import Foundation

/// One worker owns the drone socket, handshake, paging and identity keep-alives.
public final class DroneMediaSession: MediaSession, @unchecked Sendable {
    public let ip: String
    public let model: CameraModel
    public var onStatus: (@Sendable (CameraStatus) -> Void)?
    public var onProgress: (@Sendable (Double) -> Void)?
    public var onLinkLost: (@Sendable () -> Void)?
    public var onLinkRestored: (@Sendable () -> Void)?
    private let log: @Sendable (String) -> Void
    private let tx: DatalinkTransport
    private let handshake: DroneSessionHandshake
    private let cond = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var closed = false
    private var exited = false
    private var failure: String?
    private var ready = false
    private var sequence = 0
    private var cursor: UInt32 = 1
    private var seen: Set<String> = []
    private var lastBeacon = Date.distantPast
    private var lastRX = Date()
    private var lost = false
    private let pageTimeout: TimeInterval
    private let deviceIdentity: String

    public init(
        ip: String = "192.168.2.1", model: CameraModel, interfaceName: String?,
        identity: String = UUID().uuidString, deviceIdentity: String = "", port: UInt16 = 9003,
        localPort: UInt16? = 9003, pageTimeout: TimeInterval = 10,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.deviceIdentity = deviceIdentity
        self.ip = ip; self.model = model; self.log = log; self.pageTimeout = pageTimeout
        tx = DatalinkTransport(port: port, interfaceName: interfaceName, localPort: localPort, log: log)
        tx.windowModel = .mimo; tx.dropVideo = true
        handshake = DroneSessionHandshake(identity: identity)
        tx.shouldAbort = { [unowned self] in self.isClosed }
        let t = Thread { self.run() }; t.name = "avata-media"; t.start()
    }
    public var isClosed: Bool { cond.withLock { closed } }
    public var failureDescription: String? { cond.withLock { failure } }
    private func fail(_ error: Error) {
        let message = String(describing: error)
        cond.withLock { failure = message }; log("drone: \(message)")
    }
    private func submit<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            cond.lock()
            if exited { cond.unlock(); cont.resume(returning: body()); return }
            jobs.append { cont.resume(returning: body()) }; cond.signal(); cond.unlock()
        }
    }
    private func run() {
        while true {
            cond.lock()
            while jobs.isEmpty && !closed && !ready { cond.wait() }
            if closed && jobs.isEmpty { tx.close(); exited = true; cond.broadcast(); cond.unlock(); return }
            let job = jobs.isEmpty ? nil : jobs.removeFirst(); cond.unlock()
            if let job {
                job()
            } else {
                do { _ = try pump(ms: 100) } catch { fail(error); ready = false; onLinkLost?() }
            }
        }
    }
    public func close() async {
        cond.withLock {
            closed = true; cond.signal()
        }
        await submit { [self] in
            ready = false; tx.close()
        }
    }
    public func connect() async -> CameraSession.ConnectResult {
        await submit { [self] in
            do {
                guard !isClosed else { throw CancellationError() }
                try tx.open(ip: ip)
                guard tx.handshake(attempts: 8) != nil else { throw DroneSessionError.unsupportedSession }
                tx.syncSeqToPeerChannel()
                for frame in try handshake.begin() { tx.sendDumlRaw(frame, drone: true) }
                lastBeacon = Date()
                let deadline = Date().addingTimeInterval(10)
                while !handshake.isUnlocked && !isClosed && Date() < deadline { _ = try pump(ms: 100) }
                guard handshake.isUnlocked, !isClosed else { throw DroneSessionError.unsupportedSession }
                let page = try readPage()
                ready = true
                return .init(handshakeOk: true, files: page.files, moreAvailable: page.moreAvailable, model: model)
            } catch {
                fail(error); tx.close(); ready = false
                return .init(handshakeOk: false, files: [], moreAvailable: false, model: model)
            }
        }
    }
    public func nextPage() async -> (files: [CameraFile], moreAvailable: Bool) {
        await submit { [self] in
            guard ready, !isClosed else { return ([], false) }
            do { return try readPage() } catch { fail(error); return ([], false) }
        }
    }
    private func pump(ms: Int) throws -> [DjiMessage] {
        if isClosed { throw CancellationError() }
        var messages: [DjiMessage] = []
        let packets = tx.recvAll(ms: ms, precise: true)
        if !packets.isEmpty {
            lastRX = Date()
            if lost { lost = false; onLinkRestored?() }
        } else if ready && Date().timeIntervalSince(lastRX) > 5 && !lost {
            lost = true; onLinkLost?()
        }
        for packet in packets {
            // Scan outer frames by CRC, then validate each tunnel's inner frame separately.
            for frame in DumlScanner.frames(in: packet) {
                guard let message = DjiMessage(frame: Array(packet[frame.start..<(frame.start + frame.length)])) else { continue }
                if message.cmdSet == 0x51 && message.cmdId == 1 {
                    guard let inner = DroneCommands.unwrap(message) else { continue }
                    for reply in try handshake.receive(inner) { tx.sendDumlRaw(reply, drone: true) }
                } else if message.cmdSet != 0x51 {
                    messages.append(message)
                }
            }
        }
        tx.sendAck()
        if Date().timeIntervalSince(lastBeacon) >= 0.5 {
            tx.sendDumlRaw(try handshake.identityBeacon(), drone: true); lastBeacon = Date()
        }
        return messages
    }
    private func sendList(_ p: [UInt8]) {
        tx.sendDumlRaw(DjiMessage(target: 0x0102, id: 0xa000 + sequence, type: 0x260040, payload: p), drone: true)
    }
    private func envelope(subtype: UInt8, length: Int, body: [UInt8]) -> [UInt8] {
        [0x4a, subtype] + LE.u16(length | 0x1000) + LE.u16(sequence) + LE.u32(0) + body
    }
    private func readPage() throws -> (files: [CameraFile], moreAvailable: Bool) {
        guard !isClosed else { throw CancellationError() }
        sequence = (sequence + 1) & 0xffff
        let query = envelope(
            subtype: 0, length: 33,
            body: LE.u32(Int(cursor)) + [0x2d, 0, 0x0d, 1, 0] + [UInt8](repeating: 0xff, count: 8) + [0, 1, 0, 0, 0, 0])
        sendList(query)
        defer { if tx.isOpen { sendList(envelope(subtype: 4, length: 14, body: [1, 0, 0, 0])) } }
        var collector = DroneTransferCollector(sequence: sequence)
        let deadline = Date().addingTimeInterval(pageTimeout)
        while !isClosed && Date() < deadline {
            for message in try pump(ms: 100) where message.cmdSet == 0 && message.cmdId == 0x27 {
                let p = message.payload
                if p.count >= 10, p[0] == 0x4a, p.u16le(4) == sequence, p[1] == 3 {
                    sendList(envelope(subtype: 2, length: 15, body: [0, 0, 0, 0, 0]))
                }
                try collector.receive(p)
            }
            if collector.isComplete {
                let all = try collector.files().map { f in
                    var f = f; f.deviceIdentity = deviceIdentity; return f
                }
                let fresh = all.filter { seen.insert($0.id).inserted }
                let next = all.last.flatMap { file -> UInt32? in
                    if case .drone(let index, _) = file.address { return index }; return nil
                }
                let advances = next != nil && next != cursor && !fresh.isEmpty
                if let next, advances { cursor = next }
                onProgress?(1)
                return (fresh, all.count >= 45 && advances)
            }
        }
        throw isClosed ? CancellationError() : DroneSessionError.incompleteManifest
    }
}
