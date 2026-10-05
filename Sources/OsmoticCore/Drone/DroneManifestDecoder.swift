import Foundation

/// The two documented Osmosis DCF layouts. Unknown aircraft layouts fail explicitly.
public enum DroneManifestDecoder {
    public static func decode(_ bytes: [UInt8], stride: Int = 94) throws -> [CameraFile] {
        guard [67, 94].contains(stride), bytes.count % stride == 0 else { throw DroneSessionError.unsupportedManifest }
        var files: [CameraFile] = []
        var seen: Set<UInt32> = []
        for offset in Swift.stride(from: 0, to: bytes.count, by: stride) {
            let r = Array(bytes[offset..<(offset + stride)])
            let index = UInt32(r.u32le(8)), storage = Int(index >> 30)
            let directory = Int((index >> 16) & 0x3fff), number = Int(index & 0xffff)
            guard storage <= 1, (100...999).contains(directory), (1...9999).contains(number) else { throw DroneSessionError.unsupportedManifest }
            if !seen.insert(index).inserted { continue }
            let duration = r.u16le(12)
            let name = String(format: "DJI_%04d.%@", number, duration > 0 ? "MP4" : "JPG")
            var f = CameraFile(path: "DCIM/DJI_\(directory)/\(name)", thumbPath: "", storage: storage,
                               sizeBytes: r.u32le(4), durationSec: duration)
            f.address = .drone(index: index, segment: 0)
            f.storageKnown = true
            let fat = r.u32le(0)
            var c = DateComponents()
            c.year = 1980 + ((fat >> 25) & 127); c.month = (fat >> 21) & 15; c.day = (fat >> 16) & 31
            c.hour = (fat >> 11) & 31; c.minute = (fat >> 5) & 63; c.second = (fat & 31) * 2
            if (1...12).contains(c.month ?? 0), (1...31).contains(c.day ?? 0), c.hour! < 24, c.minute! < 60 {
                f.recordCaptureDate = Calendar.current.date(from: c)
            }
            files.append(f)
        }
        return files
    }
}
