import AVFoundation
import Foundation
import Testing
@testable import OpenStreamApple

/// Apple TV check of 630db1d (2026-10-01): Resume label, stock-player
/// source choice, the player's title line, and seed-sim's extra add-on.
@MainActor
struct AppleTVCheck630db1dTests {
    // MARK: 1. The title page finds a position saved under another key

    @Test func titlePageFindsProgressSavedUnderTheIMDbRecord() {
        let source = UUID()
        let fromCatalog = AppleCatalogItem(mediaID: "tt1392190", type: "movie", name: "Mad Max: Fury Road",
                                           releaseInfo: "2015")
        let fromSearch = AppleCatalogItem(mediaID: "tmdb:76341", type: "movie", name: "Mad Max: Fury Road",
                                          releaseInfo: "2015")
        let savedKey = AppleMediaIngestion.catalogRecord(instanceID: source, item: fromCatalog).id
        let pageKey = AppleMediaIngestion.catalogRecord(instanceID: source, item: fromSearch).id
        #expect(savedKey != pageKey)
        let saved = ApplePlaybackProgress(position: 65, duration: 7_222)
        let lookup: (String) -> ApplePlaybackProgress? = { $0 == savedKey ? saved : nil }

        // Before the page resolves the IMDb id: the title-and-year key only.
        #expect(AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: fromSearch, sourceID: source), progress: lookup) == pageKey)
        // Once it has: the page reads (and writes) the saved key.
        let key = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: fromSearch, sourceID: source,
                                                         resolvedMediaID: "tt1392190"),
            progress: lookup)
        #expect(key == savedKey)
        #expect(AppleTitlePagePolicy.primaryAction(type: "movie", progress: key.flatMap(lookup),
                                                   selectedEpisode: nil, isPlayable: true, hasTrailer: false)
            == .resume(episode: nil))
    }

    @Test func titlePageFindsProgressSavedUnderTheTitleAndYear() {
        let source = UUID()
        let tmdbOnly = AppleCatalogItem(mediaID: "tmdb:76341", type: "movie", name: "Mad Max: Fury Road",
                                        releaseInfo: "2015")
        let withIMDb = AppleCatalogItem(mediaID: "tt1392190", type: "movie", name: "Mad Max: Fury Road",
                                        releaseInfo: "2015")
        let savedKey = AppleMediaIngestion.catalogRecord(instanceID: source, item: tmdbOnly).id
        let older = ApplePlaybackProgress(position: 20, duration: 7_222, updatedAt: .distantPast)
        let newer = ApplePlaybackProgress(position: 65, duration: 7_222)
        let ownKey = AppleMediaIngestion.catalogRecord(instanceID: source, item: withIMDb).id
        let store: [String: ApplePlaybackProgress] = [savedKey: newer, ownKey: older]
        let key = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: withIMDb, sourceID: source), progress: { store[$0] })
        #expect(key == savedKey)
    }

    // MARK: 4. The stock player gets a release it can open

    @Test func stockPlayerRanksAContainerItOpensFirst() {
        let candidates = [
            "Show.S01E02.2160p.DV.HEVC.DDP5.1.mkv",
            "Show.S01E02.1080p.WEB.H264.AAC.mp4",
        ].map { AppleStremioHTTPPlaybackCandidate(title: $0, sourceURL: URL(string: "https://fixture.example/\($0)")!,
                                                  filename: $0) }
        let device = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: true)
        let automatic = AppleStremioCandidateRanking.playbackOrder(candidates, choice: .automatic, device: device)
        #expect(automatic.first?.filename?.hasSuffix(".mkv") == true)
        let stock = AppleStremioCandidateRanking.playbackOrder(candidates, choice: .automatic, device: device,
                                                               stockPlayerOnly: true)
        #expect(stock.map { $0.filename ?? "" } == [
            "Show.S01E02.1080p.WEB.H264.AAC.mp4", "Show.S01E02.2160p.DV.HEVC.DDP5.1.mkv",
        ])
    }

    // MARK: 6. The player names the title, not the file's own tag

    @Test func stockPlayerTitleComesFromTheTitlePage() throws {
        let items = AppleStockPlayerMetadata.items(title: "Mad Max: Fury Road")
        let title = try #require(items.first)
        #expect(title.identifier == .commonIdentifierTitle)
        #expect(title.value as? String == "Mad Max: Fury Road")
        #expect(AppleStockPlayerMetadata.items(title: "  ").isEmpty)
        #expect(AppleStockPlayerMetadata.items(title: nil).isEmpty)
    }

    // MARK: 3. Stock player stuck after a seek (clock still, rate 1)

    @Test func aStuckMinimizeStallsWaitWithMediaBufferedIsNudged() {
        #expect(NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: false, isLive: false,
            secondsStill: 4, secondsSinceLastNudge: .max))
        // Too soon: AVPlayer usually resumes by itself within a few seconds.
        #expect(!NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: false, isLive: false,
            secondsStill: 3, secondsSinceLastNudge: .max))
        // Nothing buffered: playing immediately would only stall again.
        #expect(!NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: true, isLive: false,
            secondsStill: 30, secondsSinceLastNudge: .max))
        // Paused by the viewer, or waiting for another reason.
        #expect(!NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: false, bufferEmpty: false, isLive: false,
            secondsStill: 30, secondsSinceLastNudge: .max))
        // Live is left to AVPlayer.
        #expect(!NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: false, isLive: true,
            secondsStill: 30, secondsSinceLastNudge: .max))
        // One nudge per cooldown.
        #expect(!NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: false, isLive: false,
            secondsStill: 6, secondsSinceLastNudge: 2))
        #expect(NativePlaybackEngine.stallNudgeIsDue(
            isWaitingToMinimizeStalls: true, bufferEmpty: false, isLive: false,
            secondsStill: 12, secondsSinceLastNudge: NativePlaybackEngine.stallNudgeCooldown))
    }

    // MARK: Re-check of 5298e1c: subtitle line, Native order and fallback depth

    @Test func stockPlayerLineAboveTheTitleIsTheTitlePagesNotTheFiles() throws {
        let film = AppleStockPlayerMetadata.items(title: "Mad Max: Fury Road", year: 2015)
        // No subtitle for a film: an empty one still draws AVKit's "•".
        #expect(!film.contains { $0.identifier == .iTunesMetadataTrackSubTitle })
        let date = try #require(film.first { $0.identifier == .commonIdentifierCreationDate }?.value as? Date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.year, from: date) == 2015)
        #expect(film.filter { $0.value is Date }.count == AppleStockPlayerMetadata.dateIdentifiers.count)
        let episode = AppleStockPlayerMetadata.items(title: "S51, E7", subtitle: "Saturday Night Live")
        #expect(episode.first { $0.identifier == .iTunesMetadataTrackSubTitle }?.value as? String == "Saturday Night Live")
    }

    @Test func nativeEnginePutsAnExplicitMP4BeforeUnknownContainers() {
        let names = ["SNL.S51E07.1080p.WEB.h264-A", "SNL.S51E07.720p.WEB.h264-B", "SNL.S51E07.1080p.HEVC-C",
                     "SNL.S51E07.2160p.mkv", "SNL.S51E07.720p.WEB.H264.mp4"]
        let candidates = names.map { AppleStremioHTTPPlaybackCandidate(title: $0,
            sourceURL: URL(string: "https://fixture.example/\($0)")!, filename: $0) }
        let device = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: true)
        let stock = AppleStremioCandidateRanking.playbackOrder(candidates, choice: .automatic, device: device,
                                                               stockPlayerOnly: true)
        #expect(stock.first?.filename == "SNL.S51E07.720p.WEB.H264.mp4")
        #expect(stock.last?.filename == "SNL.S51E07.2160p.mkv")
        // The MP4 named only in the URL's path counts too.
        let opaque = AppleStremioHTTPPlaybackCandidate(title: "SNL S51E07",
            sourceURL: URL(string: "https://fixture.example/dl/SNL.S51E07.mp4/abc123")!, filename: nil)
        #expect(AppleStremioCandidateRanking.traits(of: opaque).container == .mp4)
    }

    @Test func nativeEngineTriesSixStreamsBeforeGivingUp() {
        #expect(ApplePlaybackCoordinator.fallbackLimit(nativeEngine: true) == 6)
        #expect(ApplePlaybackCoordinator.fallbackLimit(nativeEngine: false) == 3)
        let base = URL(string: "https://fixture.example/stream/1")!
        #expect(!ApplePlaybackCoordinator.stockPlayerOpens(url: base, filename: "Mad.Max.2015.2160p.Remux.mkv"))
        #expect(ApplePlaybackCoordinator.stockPlayerOpens(url: base, filename: "Mad.Max.2015.DV.x265.mp4"))
        // Unnamed: still tried.
        #expect(ApplePlaybackCoordinator.stockPlayerOpens(url: base, filename: nil))
    }
}
