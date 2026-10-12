import Foundation
import Testing
@testable import OpenStreamApple

/// The Apple TV → Apple Watch awareness link: freshness, and which device the
/// watch believes when two of them claim to be playing.
///
/// Every test here is pure — a clock and a struct, no iCloud. Live sync cannot
/// be exercised on this Mac's simulators (they have no iCloud account signed
/// in), so this suite is the proof that the logic on either end of the store is
/// right; the round trip itself needs two real devices on one account.
@Suite("Device playback beacon")
struct AppleDevicePlaybackBeaconTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func tv(_ title: String = "The Whisper Man", playing: Bool = true, at offset: TimeInterval = 0)
        -> AppleDevicePlaybackState {
        AppleDevicePlaybackState(
            deviceName: "Apple TV",
            title: title,
            isPlaying: playing,
            updatedAt: epoch.addingTimeInterval(offset).timeIntervalSince1970
        )
    }

    // MARK: - Freshness

    @Test func aJustWrittenEntryIsShown() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(), now: epoch))
    }

    @Test func anEntryInsideTheWindowIsStillShown() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(), now: epoch.addingTimeInterval(89)))
    }

    /// The whole point: a television that lost power leaves its last note
    /// behind, and only the reader's clock can retire it.
    @Test func aStaleEntryIsIgnored() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(), now: epoch.addingTimeInterval(91)) == false)
    }

    @Test func aStoppedEntryIsIgnoredHoweverFresh() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(playing: false), now: epoch) == false)
    }

    @Test func anEntryWithNoTitleIsIgnored() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(""), now: epoch) == false)
    }

    /// Two devices' clocks are never exactly equal. An entry written a few
    /// seconds "in the future" is a clock skew, not a forgery.
    @Test func aSlightlyFutureEntryIsStillShown() {
        #expect(AppleDevicePlaybackPolicy.isShowable(tv(at: 20), now: epoch))
    }

    /// The writer has to refresh well inside the window, or a playing
    /// television would expire on the wrist mid-film.
    @Test func theRefreshIntervalLeavesRoomForMissedSyncs() {
        #expect(AppleDevicePlaybackPolicy.refreshInterval * 2 < AppleDevicePlaybackPolicy.staleAfter)
    }

    // MARK: - Which source wins

    @Test func nothingAnywhereIsNothing() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: nil, localIsPlaying: false, localUpdatedAt: nil, remote: nil, now: epoch)
        #expect(resolved == .nothing)
    }

    @Test func theTelevisionShowsWhenThePhoneHasNothing() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: nil, localIsPlaying: false, localUpdatedAt: nil, remote: tv(), now: epoch)
        #expect(resolved == .remote(deviceName: "Apple TV", title: "The Whisper Man"))
    }

    @Test func anEmptyPhoneTitleCountsAsNothing() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "", localIsPlaying: false, localUpdatedAt: epoch, remote: tv(), now: epoch)
        #expect(resolved == .remote(deviceName: "Apple TV", title: "The Whisper Man"))
    }

    @Test func aStaleTelevisionDoesNotDisplaceThePhone() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "Mayday", localIsPlaying: true,
            localUpdatedAt: epoch, remote: tv(at: -120), now: epoch)
        #expect(resolved == .local(title: "Mayday", isPlaying: true))
    }

    @Test func thePhoneShowsWhenTheTelevisionSaysNothing() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "Mayday", localIsPlaying: false,
            localUpdatedAt: epoch, remote: nil, now: epoch)
        #expect(resolved == .local(title: "Mayday", isPlaying: false))
    }

    @Test func theMoreRecentOfTheTwoWins() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "Mayday", localIsPlaying: true,
            localUpdatedAt: epoch.addingTimeInterval(-10), remote: tv(), now: epoch)
        #expect(resolved == .remote(deviceName: "Apple TV", title: "The Whisper Man"))
    }

    /// The documented tie-break: the phone. It is the paired device, its state
    /// arrives live rather than through an iCloud round trip, and it is the only
    /// one the watch's transport buttons can reach.
    @Test func thePhoneWinsAnExactTie() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "Mayday", localIsPlaying: true,
            localUpdatedAt: epoch, remote: tv(), now: epoch)
        #expect(resolved == .local(title: "Mayday", isPlaying: true))
    }

    @Test func aPhoneWithNoTimestampIsAmbiguousAndKept() {
        let resolved = AppleDevicePlaybackPolicy.resolve(
            localTitle: "Mayday", localIsPlaying: true,
            localUpdatedAt: nil, remote: tv(), now: epoch)
        #expect(resolved == .local(title: "Mayday", isPlaying: true))
    }

    // MARK: - How often it writes

    @Test func theFirstWriteAlwaysGoesOut() {
        #expect(AppleDevicePlaybackPolicy.shouldWrite(last: nil, title: "Mayday", now: epoch))
    }

    /// The beacon runs off the player's 0.25 s bind timer; without this it
    /// would write to iCloud four times a second.
    @Test func anUnchangedEntryIsNotRewrittenOnEveryTick() {
        #expect(AppleDevicePlaybackPolicy.shouldWrite(
            last: tv(), title: "The Whisper Man", now: epoch.addingTimeInterval(1)) == false)
    }

    @Test func aNewTitleIsWrittenAtOnce() {
        #expect(AppleDevicePlaybackPolicy.shouldWrite(
            last: tv(), title: "Mayday", now: epoch.addingTimeInterval(1)))
    }

    @Test func theHeartbeatGoesOutOnceTheIntervalHasPassed() {
        #expect(AppleDevicePlaybackPolicy.shouldWrite(
            last: tv(), title: "The Whisper Man", now: epoch.addingTimeInterval(30)))
    }

    // MARK: - The wire format

    @Test func theEntrySurvivesARoundTrip() {
        let state = tv()
        let decoded = AppleDevicePlaybackPolicy.decode(AppleDevicePlaybackPolicy.encode(state))
        #expect(decoded == state)
    }

    /// The watch target does not link this package, so
    /// `Apps/OpenStreamWatch/AppleWatchLink.swift` restates the key, the field
    /// names and the window. Change one and this fails before a device does.
    @Test func theWatchSideRestatementStillMatches() {
        #expect(AppleDevicePlaybackPolicy.cloudKey == "openstream.nowplaying.device.v1")
        #expect(AppleDevicePlaybackPolicy.staleAfter == 90)
        let json = String(decoding: AppleDevicePlaybackPolicy.encode(tv())!, as: UTF8.self)
        for field in ["deviceName", "title", "isPlaying", "updatedAt"] {
            #expect(json.contains("\"\(field)\""), "missing \(field)")
        }
        // Seconds since 1970, not since 2001 — the difference JSONEncoder's
        // default `Date` strategy would have introduced.
        #expect(json.contains("1800000000"))
    }

    @Test func rubbishInTheStoreDecodesToNothing() {
        #expect(AppleDevicePlaybackPolicy.decode(nil) == nil)
        #expect(AppleDevicePlaybackPolicy.decode(Data("not json".utf8)) == nil)
    }

    /// The name that syncs is the model, never the owner's name for the box.
    @Test func theDeviceNameCarriesNoPersonalDetail() {
        #expect(AppleDevicePlaybackBeacon.defaultDeviceName.isEmpty == false)
        #expect(AppleDevicePlaybackBeacon.defaultDeviceName.contains("’") == false)
    }
}
