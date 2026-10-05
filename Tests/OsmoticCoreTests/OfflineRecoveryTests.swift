import Foundation
import Testing

@testable import OsmoticCore

@Suite struct OfflineRecoveryTests {
    @Test func failedMissingStaleOrDifferentRecoveryBlocksJoin() {
        let now = Date(timeIntervalSince1970: 10000)
        let proof = OfflineRecoveryProof(network: "home", executable: "build-A", verifiedAt: now)
        #expect(!OfflineRecoveryPolicy.canJoin(home: nil, saved: true, proof: proof, executable: "build-A", now: now))
        #expect(!OfflineRecoveryPolicy.canJoin(home: "home", saved: false, proof: proof, executable: "build-A", now: now))
        #expect(!OfflineRecoveryPolicy.canJoin(home: "home", saved: true, proof: nil, executable: "build-A", now: now))
        #expect(!OfflineRecoveryPolicy.canJoin(home: "other", saved: true, proof: proof, executable: "build-A", now: now))
        #expect(!OfflineRecoveryPolicy.canJoin(home: "home", saved: true, proof: proof, executable: "build-B", now: now))
        #expect(
            !OfflineRecoveryPolicy.canJoin(
                home: "home", saved: true, proof: proof, executable: "build-A", now: now.addingTimeInterval(1801)))
        #expect(OfflineRecoveryPolicy.canJoin(home: "home", saved: true, proof: proof, executable: "build-A", now: now))
    }
    @Test func expiryOwnerExitAndStaleIdentity() {
        let now = Date(timeIntervalSince1970: 10000)
        #expect(OfflineRecoveryPolicy.shouldRestore(now: now, deadline: now, ownerAlive: true, requested: false))
        #expect(
            OfflineRecoveryPolicy.shouldRestore(
                now: now, deadline: now.addingTimeInterval(100), ownerAlive: false, requested: false))
        #expect(
            OfflineRecoveryPolicy.shouldRestore(
                now: now, deadline: now.addingTimeInterval(100), ownerAlive: true, requested: true))
        #expect(
            !OfflineRecoveryPolicy.shouldRestore(
                now: now, deadline: now.addingTimeInterval(100), ownerAlive: true, requested: false))
        #expect(
            !OfflineRecoveryPolicy.matchesOwner(
                expectedPID: 1, expectedLaunch: now, expectedPath: "a", pid: 1, launch: now.addingTimeInterval(5), path: "a"))
        #expect(
            OfflineRecoveryPolicy.matchesOwner(
                expectedPID: 1, expectedLaunch: now, expectedPath: "a", pid: 1, launch: now, path: "a"))
    }
}
