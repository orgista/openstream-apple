import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleLaunchWorkPolicy Tests")
struct AppleLaunchWorkPolicyTests {

    @Test(arguments: [(0, 0, false), (1, 0, true), (1, 1, false), (2, 1, true)])
    func credentialsRequireRescanUntilTheirRevisionHasBeenScanned(restored: Int, scanned: Int, expected: Bool) {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, lastScan: now, now: now,
            credentialsRestoreRevision: restored, scannedCredentialsRestoreRevision: scanned) == expected)
    }

    @Test func restoredCredentialsBypassThePersistedScanCache() throws {
        let suite = "restored-credentials-scan.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_000)
        AppleLaunchWorkPolicy.recordScan(sourceDigest: "fixture", date: now, defaults: defaults)

        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: "fixture", now: now, defaults: defaults,
            credentialsRestoreRevision: 1, scannedCredentialsRestoreRevision: 0))
        #expect(!AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: "fixture", now: now, defaults: defaults,
            credentialsRestoreRevision: 1, scannedCredentialsRestoreRevision: 1))
    }
    
    @Test("scanDelay returns 1 second when index exists, 0 otherwise")
    func testScanDelay() {
        #expect(AppleLaunchWorkPolicy.scanDelay(hasPersistedIndex: true) == .seconds(1))
        #expect(AppleLaunchWorkPolicy.scanDelay(hasPersistedIndex: false) == .zero)
    }

    @Test("shouldRescan is true when lastScan is nil or older than 10 minutes")
    func testShouldRescan() {
        let now = Date()
        let defaults = UserDefaults(suiteName: "testShouldRescan")!
        defaults.removePersistentDomain(forName: "testShouldRescan")
        
        let digest1 = "digest1"
        let digest2 = "digest2"
        
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest1, now: now, defaults: defaults) == true)
        
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest1, date: now.addingTimeInterval(-5 * 60), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest1, now: now, defaults: defaults) == false)
        
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest2, now: now, defaults: defaults) == true)
        
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest1, date: now.addingTimeInterval(-15 * 60), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest1, now: now, defaults: defaults) == true)
        
        // Fresh timestamp, but not published -> should rescan
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest2, date: now, defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: false, sourceDigest: digest2, now: now, defaults: defaults) == true)
    }
}
