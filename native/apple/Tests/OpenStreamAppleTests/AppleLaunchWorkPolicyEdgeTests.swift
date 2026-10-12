import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases the base `AppleLaunchWorkPolicyTests` suite does not cover: the
/// exact 10-minute freshness boundary, a corrupted/clock-skewed defaults
/// entry, overwriting a previous scan, and an empty digest key.
@Suite("AppleLaunchWorkPolicy Tests — edge cases")
struct AppleLaunchWorkPolicyEdgeTests {

    // Half a second inside: the stored Double cannot hold an exact 600 s age.
    @Test("shouldRescan is false just inside the 10-minute boundary")
    func testJustInsideTheBoundaryCountsAsFresh() {
        let now = Date()
        let suiteName = "testExactlyAtTheBoundary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let digest = "digest-boundary"
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest, date: now.addingTimeInterval(-599.5), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == false)
    }

    @Test("shouldRescan is true just past the 10-minute boundary (age > 600s)")
    func testJustPastTheBoundaryTriggersRescan() {
        let now = Date()
        let suiteName = "testJustPastTheBoundary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let digest = "digest-boundary"
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest, date: now.addingTimeInterval(-600.5), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == true)
    }

    /// A recorded scan later than `now` (the clock moved back) is not taken
    /// as fresh: the library rescans instead of waiting for the clock.
    @Test("a scan timestamp in the future triggers a rescan")
    func testAFutureScanTimestampTriggersARescan() {
        let now = Date()
        let suiteName = "testAFutureScanTimestamp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let digest = "digest-future"
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest, date: now.addingTimeInterval(3600), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == true)
    }

    /// If the stored dictionary's values do not match `[String: TimeInterval]`
    /// (e.g. a schema change left stale, wrongly-typed data behind), the cast
    /// fails and the digest is treated as never scanned.
    @Test("a defaults entry with the wrong value type triggers a rescan")
    func testCorruptedDefaultsEntryTriggersRescan() {
        let now = Date()
        let suiteName = "testCorruptedDefaultsEntry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let digest = "digest-corrupt"
        defaults.set([digest: "not-a-number"], forKey: "openstream.library.lastScan.v1")
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == true)
    }

    @Test("recordScan overwrites a previous timestamp for the same digest")
    func testRecordScanOverwritesThePreviousTimestamp() {
        let now = Date()
        let suiteName = "testRecordScanOverwrites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let digest = "digest-overwrite"
        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest, date: now.addingTimeInterval(-3600), defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == true)

        AppleLaunchWorkPolicy.recordScan(sourceDigest: digest, date: now, defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: digest, now: now, defaults: defaults) == false)
    }

    @Test("an empty source digest is a valid dictionary key like any other")
    func testEmptySourceDigestBehavesLikeAnyOtherKey() {
        let now = Date()
        let suiteName = "testEmptySourceDigest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        AppleLaunchWorkPolicy.recordScan(sourceDigest: "", date: now, defaults: defaults)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: "", now: now, defaults: defaults) == false)
        #expect(AppleLaunchWorkPolicy.shouldRescan(published: true, sourceDigest: "other", now: now, defaults: defaults) == true)
    }
}
