import Foundation
import Testing
@testable import OpenStreamApple

/// O10: one export→import round trip per kind of state the backup carries —
/// sources, settings, playback progress (incl. partID), watched
/// history/tombstones, the favorites/My List watchlist (incl. backdropURL),
/// and ratings — each with a non-default value, plus a check that a backup
/// written before `watchedHistory`/`watchedTombstones` existed still decodes.
@Suite("Configuration backup coverage")
struct AppleConfigurationBackupCoverageTests {
    private func source(id: UUID = UUID(), name: String = "Fixture") -> AppleSource {
        AppleSource(id: id, kind: .liveTV, name: name, url: URL(string: "https://fixture.example/")!)
    }

    private func roundTrip(_ snapshot: AppleConfigurationSnapshot) throws -> AppleConfigurationSnapshot {
        try AppleConfigurationFile.decode(try AppleConfigurationFile.encode(snapshot: snapshot)).snapshot
    }

    @Test func sourcesRoundTripNonDefaultFields() throws {
        var original = source(name: "Fixture Channel")
        original.manifestID = "fixture-manifest"
        original.version = "1.2.3"
        original.resources = ["catalog", "stream"]
        original.iptvType = .xtream
        original.discoveredItemCount = 42
        original.capabilities = ["live"]
        original.networkDisplayHost = "fixture-host.local"
        original.serverKind = .plex
        original.isEnabled = false
        let snapshot = AppleConfigurationSnapshot(sources: [original])
        let restored = try roundTrip(snapshot)
        #expect(restored == snapshot)
        let restoredSource = try #require(restored.sources.first)
        #expect(restoredSource.manifestID == "fixture-manifest")
        #expect(restoredSource.networkDisplayHost == "fixture-host.local")
        #expect(restoredSource.serverKind == .plex)
        #expect(restoredSource.discoveredItemCount == 42)
        #expect(!restoredSource.isEnabled)
    }

    @Test func settingsBlobRoundTrips() throws {
        let snapshot = AppleConfigurationSnapshot(settings: ["openstream.settings.live.favoriteChannelIDs.v1": Data([1, 2, 3])])
        let restored = try roundTrip(snapshot)
        #expect(restored.settings == snapshot.settings)
    }

    @Test func playbackProgressRoundTripsPartID() throws {
        let progress = ApplePlaybackProgress(
            position: 42, duration: 120,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), partID: "fixture-episode-part-2")
        let snapshot = AppleConfigurationSnapshot(playbackProgress: ["fixture-media-id": progress])
        let restored = try roundTrip(snapshot)
        #expect(restored.playbackProgress["fixture-media-id"] == progress)
        #expect(restored.playbackProgress["fixture-media-id"]?.partID == "fixture-episode-part-2")
    }

    @Test func watchedHistoryAndTombstonesRoundTripSeparately() throws {
        let watchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let unwatchedAt = watchedAt.addingTimeInterval(60)
        let snapshot = AppleConfigurationSnapshot(
            watchedHistory: ["fixture-watched": watchedAt],
            watchedTombstones: ["fixture-unwatched": unwatchedAt])
        let restored = try roundTrip(snapshot)
        #expect(restored.watchedHistory == ["fixture-watched": watchedAt])
        #expect(restored.watchedTombstones == ["fixture-unwatched": unwatchedAt])
    }

    /// `backdropURL` is the Continue Watching / Top Shelf fallback still and
    /// is meant to survive a restore; `artworkURL` is dropped on export by
    /// design (AppleConfigurationSnapshot.swift:93-98) and re-fetched later.
    @Test func watchlistRoundTripsBackdropURLButDropsArtwork() throws {
        let record = AppleMediaRecord(
            kind: .movie, title: "Fixture Movie", year: 2020,
            artworkURL: URL(string: "https://fixture.example/poster.jpg"),
            backdropURL: URL(string: "https://fixture.example/backdrop.jpg"),
            availability: [], isFavorite: true)
        let snapshot = AppleConfigurationSnapshot(watchlist: [record])
        let restored = try roundTrip(snapshot)
        let restoredRecord = try #require(restored.watchlist.first)
        #expect(restoredRecord.backdropURL == record.backdropURL)
        #expect(restoredRecord.isFavorite)
        #expect(restoredRecord.artworkURL == nil)
    }

    @Test func ratingsRoundTrip() throws {
        let snapshot = AppleConfigurationSnapshot(ratings: ["fixture-media-id": 5])
        let restored = try roundTrip(snapshot)
        #expect(restored.ratings == ["fixture-media-id": 5])
    }

    /// Snapshots written before `watchedHistory`/`watchedTombstones` existed
    /// have neither key at all, not empty ones — a real backward-compat file,
    /// not just an empty-dictionary case.
    @Test func decodingABackupWithoutWatchedHistoryFieldsSucceeds() throws {
        let snapshot = AppleConfigurationSnapshot(sources: [source()])
        let data = try AppleConfigurationFile.encode(snapshot: snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(json["snapshot"] as? [String: Any])
        body.removeValue(forKey: "watchedHistory")
        body.removeValue(forKey: "watchedTombstones")
        json["snapshot"] = body
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let restored = try AppleConfigurationFile.decode(legacy).snapshot
        #expect(restored.watchedHistory.isEmpty)
        #expect(restored.watchedTombstones.isEmpty)
        #expect(restored.sources.map(\.name) == snapshot.sources.map(\.name))
    }
}
