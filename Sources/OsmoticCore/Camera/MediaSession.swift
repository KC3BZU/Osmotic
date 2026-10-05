import Foundation

public protocol MediaSession: AnyObject, Sendable {
    var ip: String { get }
    var model: CameraModel { get }
    var isClosed: Bool { get }
    var failureDescription: String? { get }
    var onStatus: (@Sendable (CameraStatus) -> Void)? { get set }
    var onProgress: (@Sendable (Double) -> Void)? { get set }
    var onLinkLost: (@Sendable () -> Void)? { get set }
    var onLinkRestored: (@Sendable () -> Void)? { get set }
    func connect() async -> CameraSession.ConnectResult
    func nextPage() async -> (files: [CameraFile], moreAvailable: Bool)
    func loadNextPage() async throws -> (files: [CameraFile], moreAvailable: Bool)
    func close() async
}
extension MediaSession {
    public var failureDescription: String? { nil }
    public func loadNextPage() async throws -> (files: [CameraFile], moreAvailable: Bool) { await nextPage() }
}
extension CameraSession: MediaSession {}

public enum MediaAddress: Sendable, Hashable {
    case path
    case drone(index: UInt32, segment: UInt32)
}
