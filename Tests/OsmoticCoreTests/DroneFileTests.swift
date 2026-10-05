import Foundation
import Testing

@testable import OsmoticCore

@Suite struct DroneFileTests {
    @Test func recordDatesAndDeviceNamespace() {
        var a = CameraFile(path: "DJI_0001.JPG", thumbPath: "")
        a.address = .drone(index: 0xc064_0001, segment: 2)
        a.deviceIdentity = "one"; a.recordCaptureDate = Date(timeIntervalSince1970: 100)
        var b = a; b.deviceIdentity = "two"; b.recordCaptureDate = Date(timeIntervalSince1970: 200)
        #expect(a.id != b.id)
        #expect(a.downloadIdentity != b.downloadIdentity)
        #expect(a.originalURLPath == "/v1?file_index=3227779073&file_subtype=0&file_seg_subindex=2")
        #expect(a.thumbURLPath.contains("file_subtype=1"))
        #expect(a.sidecarCandidate() == nil)
        #expect([a, b].newestFirst().first?.deviceIdentity == "two")
        #expect(a.previewURLPaths == [a.originalURLPath])
    }
}
