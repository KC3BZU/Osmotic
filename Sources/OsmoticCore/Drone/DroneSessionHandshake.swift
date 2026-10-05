import Foundation

/// A conservative 0x51 exchange. Only a complete mutual exchange establishes readiness.
public final class DroneSessionHandshake {
    public private(set) var isUnlocked = false
    private let identity: [UInt8]
    private var serial: [UInt8]?
    private var receivedResponse = false
    private var answeredRequest = false
    private var counter = 0
    private var outerID = 0
    private var identityCounter = 0
    private var seen: Set<DjiMessageKey> = []
    private let started = DispatchTime.now().uptimeNanoseconds
    private struct DjiMessageKey: Hashable { let id: Int; let type: Int; let payload: [UInt8] }

    public init(identity: String) {
        let raw = identity.lowercased()
        let b = Array(raw)
        let formatted = b.count == 32 ? String(b[0..<8]) + "-" + String(b[8..<12]) + "-" + String(b[12..<16]) + "-" : raw
        self.identity = Array(formatted.utf8.prefix(19))
    }

    private func wrap(cmd: Int, flags: Int, id: Int, body: [UInt8]) throws -> DjiMessage {
        guard counter < 255 else { throw DroneSessionError.counterExhausted }
        counter += 1; outerID += 1
        var tail = DroneCommands.trailer; tail[5] = UInt8(counter)
        let inner = DjiMessage(target: 0xe9ee, id: id, type: flags | (0x51 << 8) | (cmd << 16), payload: body)
        return DjiMessage(target: 0xe93b, id: outerID, type: 0x015100, payload: inner.encode() + tail)
    }

    public func identityBeacon() throws -> DjiMessage {
        // Captured format, with our own installation identity, counter and monotonic uptime.
        var body = [UInt8](
            hex: "0004020037386565383937622d643231392d343964642d000401040000000000000100000101018d01000084dc22000000e00c00000000")
        body.replaceSubrange(4..<23, with: identity + [UInt8](repeating: 0, count: max(0, 19 - identity.count)))
        identityCounter += 1
        body.replaceSubrange(39..<43, with: LE.u32(identityCounter))
        body.replaceSubrange(
            43..<47, with: LE.u32(Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) & 0xffff_ffff))
        return try wrap(cmd: 0x13, flags: 0, id: 0x7c, body: body)
    }

    public func begin() throws -> [DjiMessage] {
        [try identityBeacon(), try wrap(cmd: 2, flags: 0x40, id: 0x7c, body: [5, 1, 4, 1, 0])]
    }

    public func receive(_ message: DjiMessage) throws -> [DjiMessage] {
        guard message.target == 0xeee9, message.cmdSet == 0x51 else { return [] }
        let key = DjiMessageKey(id: message.id, type: message.type, payload: message.payload)
        if seen.contains(key) { return [] }
        if message.cmdId == 8, message.flags == 0x40 {
            guard serial == nil, let body = DroneCommands.serialBody(in: message.payload) else {
                throw DroneSessionError.malformedChallenge
            }
            serial = body; seen.insert(key)
            return [
                try wrap(cmd: 8, flags: 0xc0, id: message.id, body: body),
                try wrap(cmd: 6, flags: 0x40, id: 0x7d, body: [4, 2, 0] + identity + [0] + body),
            ]
        }
        if message.cmdId == 6, let serial {
            guard DroneCommands.serialBody(in: message.payload) == serial else { throw DroneSessionError.malformedChallenge }
            if message.flags == 0xc0, message.id == 0x7d { receivedResponse = true }
            if message.flags == 0x40 {
                answeredRequest = true; seen.insert(key)
                isUnlocked = receivedResponse && answeredRequest
                return [try wrap(cmd: 6, flags: 0xc0, id: message.id, body: serial)]
            }
            isUnlocked = receivedResponse && answeredRequest
        }
        return []
    }
}
