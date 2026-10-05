import CryptoKit
import Foundation

public struct OfflineRecoveryProof: Codable, Sendable {
    public let networkHash: String
    public let executable: String
    public let verifiedAt: Date
    public init(network: String, executable: String, verifiedAt: Date) {
        networkHash = Self.hash(network); self.executable = executable; self.verifiedAt = verifiedAt
    }
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum OfflineRecoveryPolicy {
    public static func canJoin(home: String?, saved: Bool, proof: OfflineRecoveryProof?, executable: String, now: Date) -> Bool {
        guard let home, !home.isEmpty, saved, let proof,
            proof.networkHash == OfflineRecoveryProof.hash(home), proof.executable == executable
        else { return false }
        let age = now.timeIntervalSince(proof.verifiedAt)
        return age >= 0 && age <= 1800
    }
    public static func shouldRestore(now: Date, deadline: Date, ownerAlive: Bool, requested: Bool) -> Bool {
        now >= deadline || !ownerAlive || requested
    }
    public static func matchesOwner(
        expectedPID: Int32, expectedLaunch: Date, expectedPath: String,
        pid: Int32, launch: Date, path: String
    ) -> Bool {
        expectedPID == pid && expectedPath == path && abs(expectedLaunch.timeIntervalSince(launch)) < 0.001
    }
}
