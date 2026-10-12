import AVFoundation
import Foundation
import Testing
@testable import OpenStreamApple

// Generated local media is intentionally absent from sanitized public exports.
private let macCaptionsSelectionFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/out/mp4-h264-aac-subtitles.mp4")
private let macCaptionsSelectionFixtureAvailable = FileManager.default.fileExists(
    atPath: macCaptionsSelectionFixture.path
)

/// The stock player's CC menu against a real asset with two legible tracks
/// (`Fixtures/out/mp4-h264-aac-subtitles.mp4`: English and French mov_text).
///
/// AVKit's menu does nothing more than `select(_:in:)` on the item, so each
/// test makes that call itself and then replays what the app does afterwards:
/// the host's bind tick re-running discovery, and an add-on's subtitles
/// arriving late, which is when the engine re-applies the captions setting.
///
/// The time limit is the hang guard for `waitUntil`, which has no deadline of
/// its own.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppleMacCaptionsSelectionTests {
    private static let fixture = macCaptionsSelectionFixture

    @Test func theMacHostMirrorsTheStockCaptionsMenu() {
        #expect(ApplePlayerHost.mirrorsStockSubtitleSelection)
    }

    @Test(.enabled(if: macCaptionsSelectionFixtureAvailable)) func choosingALanguageSurvivesRediscoveryAndLateAddonSubtitles() async throws {
        let session = try await Session(preference: .off)
        defer { session.stop() }
        try await session.chooseInStockMenu(language: "fr")
        await session.rediscover()
        #expect(session.selectedLanguage == "fr")
        #expect(session.engine.activeSubtitleTrackID == session.trackID(language: "fr"))
    }

    @Test(.enabled(if: macCaptionsSelectionFixtureAvailable)) func choosingOnSurvivesRediscovery() async throws {
        let session = try await Session(preference: .off)
        defer { session.stop() }
        try await session.chooseInStockMenu(language: "en")
        await session.rediscover()
        #expect(session.selectedLanguage == "en")
        #expect(session.engine.activeSubtitleTrackID == session.trackID(language: "en"))
    }

    @Test(.enabled(if: macCaptionsSelectionFixtureAvailable)) func offStaysOffAfterTheSettingTurnedCaptionsOn() async throws {
        let session = try await Session(preference: .always)
        defer { session.stop() }
        #expect(session.selectedLanguage == "en")
        try await session.chooseInStockMenu(language: nil)
        await session.rediscover()
        #expect(session.selectedLanguage == nil)
        #expect(session.engine.activeSubtitleTrackID == nil)
        #expect(session.engine.subtitleCues.isEmpty)
    }

    @Test(.enabled(if: macCaptionsSelectionFixtureAvailable)) func switchingBetweenLanguagesKeepsTheLastChoice() async throws {
        let session = try await Session(preference: .off)
        defer { session.stop() }
        try await session.chooseInStockMenu(language: "en")
        try await session.chooseInStockMenu(language: "fr")
        await session.rediscover()
        #expect(session.selectedLanguage == "fr")
    }

    /// Without the mirror the Mac had before this fix: the late add-on batch
    /// re-applies the Off setting and takes the viewer's captions away.
    @Test(.enabled(if: macCaptionsSelectionFixtureAvailable)) func withoutTheMirrorALateAddonBatchUndoesTheChoice() async throws {
        let session = try await Session(preference: .off, mirrors: false)
        defer { session.stop() }
        try await session.chooseInStockMenu(language: "en")
        await session.rediscover()
        #expect(session.selectedLanguage == nil)
    }

    /// One native-engine playback of the fixture with the mirror the Mac
    /// host binds.
    @MainActor
    private final class Session {
        let engine = NativePlaybackEngine()
        let selection: ApplePlayerSubtitleSelection?
        let item: AVPlayerItem
        let group: AVMediaSelectionGroup

        init(preference: AppleCaptionsPreference, mirrors: Bool = true) async throws {
            engine.applyCaptionPreferences(preference: preference, languages: [], languagesAreExplicit: false)
            engine.externalSubtitleDataLoader = { _ in
                Data("1\n00:00:00,000 --> 00:01:00,000\nAdd-on cue\n".utf8)
            }
            try await engine.load(ApplePlaybackRequest(url: AppleMacCaptionsSelectionTests.fixture,
                                                       autoplay: false, mediaID: "mac-captions",
                                                       sourceKind: .files))
            item = try #require(engine.avPlayer?.currentItem)
            // AVKit offers its CC menu once the item is ready, not before.
            try await Self.waitUntil { [item] in item.status == .readyToPlay }
            group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
            selection = mirrors ? ApplePlayerSubtitleSelection(engine: engine) : nil
            selection?.bind(to: item)
            try await Self.waitUntil { mirrors == false || self.selection?.isObserving == true }
        }

        var selectedLanguage: String? {
            item.currentMediaSelection.selectedMediaOption(in: group).flatMap(Self.language)
        }

        func trackID(language: String) -> Int? {
            engine.subtitleTracks.first { $0.language.map(AppleSubtitleTrackFilter.normalized)
                == AppleSubtitleTrackFilter.normalized(language) }?.id
        }

        /// What AVKit's CC menu does: select the visible option for that
        /// language, or nothing for Off.
        func chooseInStockMenu(language: String?) async throws {
            let option = language.flatMap { wanted in
                group.options.first {
                    Self.language($0) == wanted && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                }
            }
            if language != nil { _ = try #require(option) }
            item.select(option, in: group)
            let expected = language.flatMap(trackID(language:))
            try await Self.waitUntil { self.selection == nil || self.engine.activeSubtitleTrackID == expected }
        }

        /// The host's bind ticks, and an add-on's subtitles arriving after the
        /// stream's own — the engine's moment to re-apply the setting.
        func rediscover() async {
            for _ in 0..<4 {
                selection?.bind(to: item)
                try? await Task.sleep(for: .milliseconds(30))
            }
            engine.addExternalSubtitleTracks([
                AppleExternalSubtitleTrack(id: "late-addon", languageCode: "de", displayName: "Deutsch",
                                           url: URL(string: "https://fixture.example/late.srt")!)
            ])
            for _ in 0..<4 {
                selection?.bind(to: item)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        func stop() { engine.stop() }

        private static func language(_ option: AVMediaSelectionOption) -> String? {
            (option.extendedLanguageTag ?? option.locale?.identifier).map { String($0.prefix(2)) }
        }

        /// Waits for AVFoundation's side of a change (item readiness, the
        /// selection KVO reaching the mirror on the main queue). Nothing here
        /// can be awaited directly, and a wall-clock deadline failed whenever
        /// the parallel gate kept the main actor busy for a few seconds; the
        /// suite's time limit fails a change that never lands.
        private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            while !condition() {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

/// The same CC-menu choice on the default engine, which pins the legible
/// group deselected while the app owns captions (AetherEngine Sodalite#38/#65)
/// — the reason the Mac's menu did nothing at all. Opt-in: it runs the real
/// engine and its loopback server, which the gate keeps out of parallel runs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_MAC_CAPTIONS_AETHER"] == "1" && macCaptionsSelectionFixtureAvailable))
@MainActor
func aetherKeepsTheStockMenusChoice() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mp4-h264-aac-subtitles.mp4")
    let engine = try AetherPlaybackEngine()
    engine.applyCaptionPreferences(preference: .off, languages: [], languagesAreExplicit: false)
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    defer { coordinator.stop() }
    await coordinator.begin(ApplePlaybackRequest(url: fixture, mediaID: "mac-captions-aether", sourceKind: .files))
    let selection = ApplePlayerSubtitleSelection(engine: engine)
    var item: AVPlayerItem?
    var group: AVMediaSelectionGroup?
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
        if let current = engine.avPlayer?.currentItem, current.status == .readyToPlay {
            selection.bind(to: current)
            if selection.isObserving {
                item = current
                group = try await current.asset.loadMediaSelectionGroup(for: .legible)
                break
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    print("aether route=\(engine.route) tracks=\(engine.subtitleTracks.map { "\($0.id):\($0.language ?? "-")" })")
    let playing = try #require(item)
    let legible = try #require(group)
    print("aether legible options=\(legible.options.map { $0.extendedLanguageTag ?? "-" })")
    let english = try #require(legible.options.first { $0.extendedLanguageTag?.hasPrefix("en") == true })
    playing.select(english, in: legible)
    for _ in 0..<40 {
        selection.bind(to: playing)
        try await Task.sleep(for: .milliseconds(50))
    }
    let selected = playing.currentMediaSelection.selectedMediaOption(in: legible)
    print("aether after choice: selected=\(selected?.extendedLanguageTag ?? "none") active=\(String(describing: engine.activeSubtitleTrackID))")
    #expect(selected?.extendedLanguageTag?.hasPrefix("en") == true)
    #expect(engine.activeSubtitleTrackID != nil)
    playing.select(nil, in: legible)
    for _ in 0..<20 {
        selection.bind(to: playing)
        try await Task.sleep(for: .milliseconds(50))
    }
    print("aether after off: selected=\(playing.currentMediaSelection.selectedMediaOption(in: legible)?.extendedLanguageTag ?? "none") active=\(String(describing: engine.activeSubtitleTrackID))")
    #expect(playing.currentMediaSelection.selectedMediaOption(in: legible) == nil)
    #expect(engine.activeSubtitleTrackID == nil)
}
