import Testing
@testable import OsmoticCore

@Suite struct DroneHandshakeTests {
    @Test func framingAndCounters() throws {
        let h = DroneSessionHandshake(identity: "12345678-abcd-1234-abcd-123456789abc")
        let first = try h.begin()
        #expect(first.count == 2)
        #expect(first[0].target == 0xe93b)
        let inner = try #require(DroneCommands.unwrap(first[1]))
        #expect(inner.target == 0xe9ee)
        #expect(inner.payload == [5, 1, 4, 1, 0])
        #expect(DjiMessage(frame: first[1].encode()) == first[1])
        #expect(first[0].id < first[1].id)
        #expect(Array(first[0].payload.suffix(22))[5] < Array(first[1].payload.suffix(22))[5])
        var damaged = first[1]; damaged.payload[4] ^= 1
        #expect(DroneCommands.unwrap(damaged) == nil)
    }
    @Test func challengeAndApproval() throws {
        let h = DroneSessionHandshake(identity: "12345678-abcd-1234-abcd-123456789abc")
        _ = try h.begin()
        let serial = Array("1234567890ABCDEFGHJK".utf8)
        let challenge = DjiMessage(target: 0xeee9, id: 1, type: 0x085140, payload: [0, 0, 0x11] + serial + [0])
        let replies = try h.receive(challenge)
        #expect(replies.count == 2)
        #expect(DroneCommands.unwrap(replies[0])?.payload == challenge.payload)
        #expect(!h.isUnlocked)
        #expect(try h.receive(challenge).isEmpty)
        let response = DjiMessage(target: 0xeee9, id: 0x7d, type: 0x0651c0, payload: challenge.payload)
        _ = try h.receive(response)
        #expect(!h.isUnlocked)
        let request = DjiMessage(target: 0xeee9, id: 6, type: 0x065140, payload: challenge.payload)
        let echo = try h.receive(request)
        #expect(DroneCommands.unwrap(echo[0])?.id == 6)
        #expect(h.isUnlocked)
    }
    @Test func malformedChallengeRejected() throws {
        let h = DroneSessionHandshake(identity: "12345678-abcd-1234-abcd-123456789abc")
        _ = try h.begin()
        #expect(throws: DroneSessionError.self) {
            _ = try h.receive(DjiMessage(target: 0xeee9, id: 1, type: 0x085140, payload: [0]))
        }
        #expect(!h.isUnlocked)
    }
    @Test func localBindConflict() throws {
        let a = DatalinkTransport(port: 19003, localPort: 19004, log: { _ in })
        let b = DatalinkTransport(port: 19003, localPort: 19004, log: { _ in })
        try a.open(ip: "127.0.0.1")
        defer { a.close(); b.close() }
        #expect(throws: DatalinkError.self) { try b.open(ip: "127.0.0.1") }
        #expect(!b.isOpen)
        let c = DatalinkTransport(port: 19003, log: { _ in })
        try c.open(ip: "127.0.0.1"); c.close()
    }
}
