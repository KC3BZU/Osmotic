import Foundation
import Testing

@testable import OsmoticCore

@Suite struct DroneMediaTests {
    func chunk(seq: Int = 9, index: Int, final: Bool, body: [UInt8], count: Int = 1, total: Int = 102) -> [UInt8] {
        let extra = index == 0 ? LE.u32(count) + LE.u32(total) : []
        return [0x4a, 1] + LE.u16(10 + extra.count + body.count | (final ? 0x1000 : 0)) + LE.u16(seq) + LE.u32(index) + extra
            + body
    }
    func record(stride: Int = 94) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: stride)
        r.replaceSubrange(0..<4, with: LE.u32((46 << 25) | (10 << 21) | (5 << 16) | (12 << 11)))
        r.replaceSubrange(4..<8, with: LE.u32(12345))
        r.replaceSubrange(8..<12, with: LE.u32((100 << 16) | 7))
        r[12] = 5
        return r
    }
    @Test func reorderedCompleteAndDuplicate() throws {
        var c = DroneTransferCollector(sequence: 9)
        let r = record()
        try c.receive(chunk(index: 1, final: true, body: Array(r.suffix(50))))
        #expect(!c.isComplete)
        let start = chunk(index: 0, final: false, body: Array(r.prefix(44)))
        try c.receive(start); try c.receive(start)
        let files = try c.files()
        #expect(files.count == 1)
        #expect(files[0].originalURLPath == "/v1?file_index=6553607&file_subtype=0&file_seg_subindex=0")
        #expect(files[0].captureDate != nil)
        #expect(files[0].recordTimestamp == UInt32(record().u32le(0)))
    }
    @Test func missingWrongSequenceAndConflicts() throws {
        var c = DroneTransferCollector(sequence: 9)
        try c.receive(chunk(seq: 8, index: 0, final: true, body: record()))
        #expect(!c.isComplete)
        try c.receive(chunk(index: 0, final: false, body: []))
        #expect(throws: DroneSessionError.self) { try c.files() }
        #expect(throws: DroneSessionError.self) { try c.receive(chunk(index: 0, final: false, body: [1])) }
    }
    @Test func limitsAndTruncation() throws {
        var c = DroneTransferCollector(sequence: 9)
        #expect(throws: DroneSessionError.self) { try c.receive(chunk(index: 0, final: true, body: [], total: 9 << 20)) }
        var d = DroneTransferCollector(sequence: 9)
        try d.receive(chunk(index: 0, final: true, body: Array(record().dropLast())))
        #expect(throws: DroneSessionError.self) { try d.files() }
    }
    @Test func emptyAndLongAndMini() throws {
        var c = DroneTransferCollector(sequence: 9)
        try c.receive(chunk(index: 0, final: true, body: [], count: 0, total: 8))
        #expect(try c.files().isEmpty)
        var d = DroneTransferCollector(sequence: 9)
        try d.receive(chunk(index: 0, final: true, body: record() + record() + record(), count: 3, total: 290))
        #expect(try d.files().count == 1)  // duplicate indices dedup
        var e = DroneTransferCollector(sequence: 9)
        try e.receive(chunk(index: 0, final: true, body: record(stride: 67), total: 75))
        #expect(try e.files().count == 1)
    }
    @Test func fakeDroneSessionAndRelease() async throws {
        let drone = try FakeDrone(manifest: record())
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.5, log: { _ in })
        let result = await session.connect()
        #expect(result.handshakeOk)
        #expect(result.files.count == 1)
        let page = await session.nextPage()
        #expect(page.files.isEmpty)
        #expect(!page.moreAvailable)
        await session.close(); await session.close()
        #expect(session.isClosed)
        try await Task.sleep(for: .milliseconds(80))
        #expect(drone.releases == 2)
    }
    @Test func documentedMiniOpenFallback() async throws {
        let drone = try FakeDrone(manifest: record(), openBody: [5, 0xff, 4, 2, 0])
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.5, log: { _ in })
        let result = await session.connect()
        await session.close()
        #expect(result.handshakeOk)
        #expect(result.files.count == 1)
    }
    @Test func diagnosticListCanTestAnAlreadyOpenAircraft() async throws {
        let drone = try FakeDrone(manifest: record(), openBody: [0])
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.5, log: { _ in })
        let result = await session.probeExistingMediaList()
        await session.close()
        #expect(result.handshakeOk)
        #expect(result.files.count == 1)
    }
    @Test func catalogueContinuesWhenPeerDoesNotEchoCommandAcks() async throws {
        let drone = try FakeDrone(manifest: record(), requirePreviousCommandAck: true)
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.5, log: { _ in })
        let result = await session.probeExistingMediaList()
        await session.close()
        #expect(result.handshakeOk)
        #expect(result.files.count == 1)
    }
    @Test func fakeTimeoutReleases() async throws {
        let drone = try FakeDrone(manifest: nil)
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.2, log: { _ in })
        let result = await session.connect()
        #expect(!result.handshakeOk)
        #expect(session.failureDescription != nil)
        await session.close()
        try await Task.sleep(for: .milliseconds(80))
        #expect(drone.releases == 1)
    }

    @Test func manifestSpansUDPDatagrams() async throws {
        let drone = try FakeDrone(manifest: record(), splitManifest: true)
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.4, log: { _ in })
        let result = await session.connect()
        await session.close()
        #expect(result.handshakeOk)
        #expect(result.files.count == 1)
    }

    @Test func olderPageTimeoutIsRetryableFailure() async throws {
        let drone = try FakeDrone(manifest: record(), failAfterFirstPage: true)
        defer { drone.stop() }
        let session = DroneMediaSession(
            ip: "127.0.0.1", model: CameraModel.resolve(modelId: 0x77, name: ""),
            interfaceName: nil, port: drone.port, localPort: nil, pageTimeout: 0.2, log: { _ in })
        let result = await session.connect()
        #expect(result.handshakeOk)
        await #expect(throws: DroneSessionError.self) { _ = try await session.loadNextPage() }
        #expect(session.failureDescription != nil)
        let compat = await session.nextPage()
        #expect(compat.moreAvailable)
        await session.close()
    }

}
