import Foundation

/// Complete, bounded and sequence-specific manifest reassembly. No partial file lists escape.
public struct DroneTransferCollector {
    public let sequence: Int
    private var chunks: [Int: [UInt8]] = [:]
    private var finalIndex: Int?
    private var count: Int?
    private var total: Int?
    public init(sequence: Int) { self.sequence = sequence }
    public var isComplete: Bool {
        guard let finalIndex, let total, count != nil, chunks.count == finalIndex + 1,
              (0...finalIndex).allSatisfy({ chunks[$0] != nil }) else { return false }
        return chunks.values.reduce(0) { $0 + $1.count } == total - 8
    }
    public mutating func receive(_ p: [UInt8]) throws {
        guard p.count >= 10, p[0] == 0x4a, p[1] == 1, p.u16le(4) == sequence else { return }
        guard p.u16le(2) & 0xfff == p.count, p.u16le(2) & 0xe000 == 0 else { throw DroneSessionError.incompleteManifest }
        let index = p.u32le(6)
        guard index <= 8192 else { throw DroneSessionError.incompleteManifest }
        var offset = 10
        if index == 0 {
            guard p.count >= 18 else { throw DroneSessionError.incompleteManifest }
            let n = p.u32le(10), bytes = p.u32le(14)
            guard n <= 100000, bytes >= 8, bytes <= 8 << 20 else { throw DroneSessionError.incompleteManifest }
            if let count, count != n { throw DroneSessionError.incompleteManifest }
            if let total, total != bytes { throw DroneSessionError.incompleteManifest }
            count = n; total = bytes; offset = 18
        }
        let data = Array(p.dropFirst(offset))
        if let existing = chunks[index], existing != data { throw DroneSessionError.incompleteManifest }
        if let finalIndex, index > finalIndex { throw DroneSessionError.incompleteManifest }
        if p.u16le(2) & 0x1000 != 0 {
            if let finalIndex, finalIndex != index { throw DroneSessionError.incompleteManifest }
            guard chunks.keys.allSatisfy({ $0 <= index }) else { throw DroneSessionError.incompleteManifest }
            finalIndex = index
        }
        chunks[index] = data
        guard chunks.values.reduce(0, { $0 + $1.count }) <= 8 << 20 else { throw DroneSessionError.incompleteManifest }
    }
    public func files() throws -> [CameraFile] {
        guard isComplete, let count, let total, let finalIndex else { throw DroneSessionError.incompleteManifest }
        if count == 0 { guard total == 8 else { throw DroneSessionError.unsupportedManifest }; return [] }
        guard (total - 8) % count == 0 else { throw DroneSessionError.unsupportedManifest }
        return try DroneManifestDecoder.decode((0...finalIndex).flatMap { chunks[$0]! }, stride: (total - 8) / count)
    }
}
