import Foundation

/// Drone tunnel framing adapted from Osmosis (KonradIT, MIT). No flight or capture commands.
public enum DroneCommands {
    static let trailer = [UInt8](hex: "39fdb2ae020100000079102e9b010000000000000000")

    public static func unwrap(_ outer: DjiMessage) -> DjiMessage? {
        guard outer.cmdSet == 0x51, outer.cmdId == 1, outer.payload.count >= 13 else { return nil }
        let length = outer.payload.u16le(1) & 0x3ff
        guard length >= 13, outer.payload.count == length + 22 else { return nil }
        return DjiMessage(frame: Array(outer.payload.prefix(length)))
    }

    static func serialBody(in payload: [UInt8]) -> [UInt8]? {
        func isChar(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) }
        var candidates: [[UInt8]] = []
        var i = 0
        while i < payload.count {
            if !isChar(payload[i]) { i += 1; continue }
            let start = i
            while i < payload.count && isChar(payload[i]) { i += 1 }
            if (12...24).contains(i - start), start > 0, i < payload.count, payload[i] == 0 {
                candidates.append([0, 0, payload[start - 1]] + Array(payload[start..<i]) + [0])
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

public enum DroneSessionError: Error, Sendable, CustomStringConvertible {
    case unsupportedSession, malformedChallenge, counterExhausted, incompleteManifest, unsupportedManifest, nonAdvancingPage
    public var description: String {
        switch self {
        case .unsupportedSession: "The aircraft did not complete the experimental QuickTransfer session."
        case .malformedChallenge: "The aircraft sent an unrecognized identity challenge."
        case .counterExhausted: "The experimental session reached its tunnel counter limit. Reconnect."
        case .incompleteManifest: "The aircraft media list was incomplete."
        case .nonAdvancingPage: "The aircraft repeated a full media page. Older media remains unverified; retry listing."
        case .unsupportedManifest: "The aircraft returned an unrecognized media list format."
        }
    }
}
