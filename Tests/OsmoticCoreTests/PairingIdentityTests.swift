import Foundation
import Testing

@testable import OsmoticCore

@Suite struct PairingIdentityTests {
    @Test func repeatedConnectionsKeepTheSameApprovalIdentity() throws {
        let suite = "avata-identity-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PairingIdentity.load(from: defaults)
        #expect(first.utf8.count == 32)
        #expect(first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(PairingIdentity.load(from: defaults) == first)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(PairingIdentity.load(from: reopened) == first)
    }

    @Test func anInvalidSavedIdentityIsReplacedOnce() throws {
        let suite = "avata-invalid-identity-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bad", forKey: "pairingIdentifier")
        let replacement = PairingIdentity.load(from: defaults)
        #expect(replacement != "bad")
        #expect(replacement.utf8.count == 32)
        #expect(PairingIdentity.load(from: defaults) == replacement)
    }
}
