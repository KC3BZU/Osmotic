import Foundation
import Testing

@testable import OsmoticCore

@Suite struct AvataPairingTests {
    @Test func avataProfileUsesDroneTransport() {
        let model = CameraModel.resolve(modelId: 0x0077, name: "Renamed aircraft")
        #expect(model.name == "DJI Avata 2")
        #expect(model.isDrone)
        #expect(model.datalinkPort == 9003)
        #expect(!model.tcpPoke)
        #expect(model.supportsMediaTransfer)
        #expect(!model.supportsCaptureControl)
        #expect(!model.verified)
    }

    @Test func unknownDroneRemainsUnsupported() {
        #expect(!CameraModel.resolve(modelId: 0x0088, name: nil).supportsMediaTransfer)
        #expect(CameraModel.resolve(modelId: 0x0020, name: nil).supportsMediaTransfer)
    }

    @Test func dronePairingUsesFlyTokenOnEveryRetry() throws {
        let clock = FakeClock()
        let identifier = "0123456789abcdef0123456789abcdef"
        let flow = PairingFlow(bleName: "Test aircraft", savedPassword: nil, identifier: identifier, token: "DJI FLY")
        var writes: [[UInt8]] = []
        flow.write = { writes.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        clock.advance(to: 9)
        let pairs = writes.compactMap { DjiMessage(frame: $0) }.filter { $0.cmdSet == 7 && $0.cmdId == 0x45 }
        #expect(pairs.count == 4)
        let expected = [UInt8](hex: "20") + Array(identifier.utf8) + [7] + Array("DJI FLY".utf8)
        #expect(pairs.allSatisfy { $0.payload == expected })
    }

    @Test func approvalGatesCredentialRequestsAndUnsolicitedCredentials() {
        let clock = FakeClock()
        let flow = PairingFlow(bleName: "Test aircraft", savedPassword: nil, token: "DJI FLY")
        var writes: [[UInt8]] = []
        var events: [PairingFlow.Event] = []
        flow.write = { writes.append($0) }
        flow.emit = { events.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        flow.onMessage(reply(0x45, [0, 2]))
        flow.onMessage(reply(7, [0, 4] + Array("test".utf8)))
        flow.onMessage(reply(0x0e, [0, 8] + Array("testpass".utf8)))
        clock.advance(to: 10)
        #expect(events == [.approvalRequired])
        #expect(!writes.compactMap { DjiMessage(frame: $0) }.contains { $0.cmdSet == 7 && [7, 0x0e].contains($0.cmdId) })
        let approval = DjiMessage(target: 0x0207, id: 0x1234, type: 0x460740, payload: [1])
        flow.onMessage(approval)
        clock.advance(to: 12)
        #expect(events == [.approvalRequired, .paired])
        #expect(writes.compactMap { DjiMessage(frame: $0) }.contains { $0.cmdId == 7 && $0.flags == 0x40 })
    }

    @Test func cancelledPairingIgnoresTimersAndMessages() {
        let clock = FakeClock()
        let flow = PairingFlow(bleName: "Test aircraft", savedPassword: nil, token: "DJI FLY")
        var writes: [[UInt8]] = []
        var events: [PairingFlow.Event] = []
        flow.write = { writes.append($0) }
        flow.emit = { events.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        flow.cancel()
        let initialCount = writes.count
        clock.advance(to: 20)
        flow.onMessage(reply(0x45, [0, 1]))
        #expect(writes.count == initialCount)
        #expect(events.isEmpty)
    }

    private func reply(_ command: Int, _ payload: [UInt8]) -> DjiMessage {
        DjiMessage(target: 0x0207, id: 0x8000, type: 0xc0 | (7 << 8) | (command << 16), payload: payload)
    }
}
