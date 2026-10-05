import Darwin
import Foundation

@testable import OsmoticCore

final class FakeDrone: @unchecked Sendable {
    let port: UInt16
    let manifest: [UInt8]?
    let failAfterFirstPage: Bool
    private var queries = 0
    let splitManifest: Bool
    private let socketFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var released = 0
    private var threadDone = false
    var releases: Int { lock.withLock { released } }
    init(manifest: [UInt8]?, splitManifest: Bool = false, failAfterFirstPage: Bool = false) throws {
        self.failAfterFirstPage = failAfterFirstPage
        self.splitManifest = splitManifest
        self.manifest = manifest
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        self.socketFD = socketFD
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(socketFD); throw DatalinkError.bind(errno) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketFD, $0, &len) }
        }
        port = UInt16(bigEndian: address.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread { self.run() }.start()
    }
    func stop() {
        lock.withLock { stopped = true }
        while !lock.withLock({ threadDone }) { Thread.sleep(forTimeInterval: 0.01) }
        Darwin.close(socketFD)
    }
    private func run() {
        defer { lock.withLock { threadDone = true } }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, b.baseAddress, b.count, 0, $0, &len)
                    }
                }
            }
            guard n >= 8 else { continue }
            let p = Array(buffer.prefix(n))
            func send(_ bytes: [UInt8]) {
                _ = bytes.withUnsafeBytes { b in
                    withUnsafePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socketFD, b.baseAddress, b.count, 0, $0, len)
                        }
                    }
                }
            }
            func reply(_ message: DjiMessage, split: Bool = false) {
                let bytes = message.encode()
                let pieces = split ? [Array(bytes.prefix(30)), Array(bytes.dropFirst(30))] : [bytes]
                for (i, piece) in pieces.enumerated() {
                    let routing = DatalinkHeaders.routingHeader(seq: 0x2000 + i * 8, cmdCounter: 1, drone: true)
                    send(
                        DatalinkHeaders.udpHeader(
                            pktType: 3, payloadLen: routing.count + piece.count,
                            sessionId: p.u16le(2), seq: 0x2000 + i * 8) + routing + piece)
                }
            }
            func tunnel(cmd: Int, flags: Int, id: Int, body: [UInt8]) {
                let inner = DjiMessage(target: 0xeee9, id: id, type: flags | 0x5100 | cmd << 16, payload: body)
                reply(DjiMessage(target: 0x3be9, id: 1, type: 0x015100, payload: inner.encode() + DroneCommands.trailer))
            }
            if p[6] == 0 { send(p); continue }
            guard p[6] == 5, p.count > 20, let m = DjiMessage(frame: Array(p.dropFirst(20))) else { continue }
            let serial = [UInt8](hex: "000011") + Array("1234567890ABCDEFGHJK".utf8) + [0]
            if let inner = DroneCommands.unwrap(m) {
                if inner.cmdId == 2 { tunnel(cmd: 8, flags: 0x40, id: 1, body: serial) }
                if inner.cmdId == 6 && inner.flags == 0x40 {
                    tunnel(cmd: 6, flags: 0xc0, id: inner.id, body: serial)
                    tunnel(cmd: 6, flags: 0x40, id: 7, body: serial)
                }
            }
            if m.cmdSet == 0, m.cmdId == 0x26, m.payload.count >= 10 {
                let seq = m.payload.u16le(4)
                if m.payload[1] == 4 { lock.withLock { released += 1 } }
                if m.payload[1] == 0 {
                    queries += 1
                    reply(
                        .init(
                            target: 0x0201, id: 1, type: 0x270000, payload: [0x4a, 3] + LE.u16(0x100a) + LE.u16(seq) + LE.u32(0)))
                }
                if m.payload[1] == 2, let manifest, !(failAfterFirstPage && queries > 1) {
                    let count = manifest.count / 94
                    reply(
                        .init(
                            target: 0x0201, id: 1, type: 0x270000,
                            payload: [0x4a, 1] + LE.u16((18 + manifest.count) | 0x1000) + LE.u16(seq) + LE.u32(0) + LE.u32(count)
                                + LE.u32(8 + manifest.count) + manifest), split: splitManifest)
                }
            }
        }
    }
}
