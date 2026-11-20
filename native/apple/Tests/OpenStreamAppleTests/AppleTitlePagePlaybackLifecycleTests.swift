import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized)
struct AppleTitlePagePlaybackLifecycleTests {
    @Test(arguments: [ApplePlaybackEngineKind.openStream, .native])
    func playbackUsesTheSelectedEngineAfterBrowsing(preferred: ApplePlaybackEngineKind) throws {
        let suite = "openstream.tests.title-playback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: TitlePlaybackCredentials())
        settings.playbackEngine = preferred
        let browsing = ApplePlaybackCoordinator.forBrowsing()
        browsing.beginResolving()

        let filename = preferred == .openStream ? "film.mkv" : "film.mp4"
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/\(filename)")),
            mediaID: "fixture-film", sourceKind: .files, hints: .init(filename: filename))
        let presentation = AppleMediaPlayerPresentation(request: request, settings: settings)

        #expect(presentation.coordinator !== browsing)
        #expect(presentation.coordinator.engine.kind == preferred)
        #expect(settings.playbackEngine == preferred)
        #expect(!settings.engineFellBackToNative)
        #expect(presentation.coordinator.phase == .idle)
        #expect(browsing.phase == .resolving)
    }

    @Test func anExplicitPlaybackEngineSurvivesTheBrowsingCoordinator() throws {
        let suite = "openstream.tests.title-override.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: TitlePlaybackCredentials())
        settings.playbackEngine = .native
        let browsing = ApplePlaybackCoordinator.forBrowsing()
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/film.mkv")),
            mediaID: "fixture-film", sourceKind: .files, hints: .init(filename: "film.mkv"))
        let presentation = AppleMediaPlayerPresentation(request: request, settings: settings,
            engineOverride: .openStream)

        #expect(presentation.coordinator !== browsing)
        #expect(presentation.coordinator.engine.kind == .openStream)
        #expect(settings.playbackEngine == .native)
    }

    @Test(arguments: [false, true])
    func backgroundSavePersistsAnActivePlayerWithAThousandHistoryEntries(fileBacked: Bool) async throws {
        let suite = "openstream.tests.background-progress.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ApplePlaybackStore(defaults: defaults, blobDirectory: fileBacked ? directory : nil)
        let history = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("tt\(2_000_000 + $0)", ApplePlaybackProgress(position: 120, duration: 6_000))
        })
        store.restoreConfigurationProgress(history)
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.paused])
        engine.duration = 6_000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.progressWriter = { position, duration in
            store.save(mediaID: "tt2000000", position: position, duration: duration)
        }
        defer {
            coordinator.setOnScreen(false)
            coordinator.stop()
        }
        await coordinator.begin(ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/film.mp4")),
            mediaID: "tt2000000", sourceKind: .files))
        engine.position = 600
        coordinator.setOnScreen(true)
        let start = ContinuousClock.now
        ApplePlaybackCoordinator.saveProgressOnScreen()
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .milliseconds(250))
        #expect(store.progress(for: "tt2000000")?.position == 600)
        #expect(store.configurationProgress().count == history.count)
        let reopened = ApplePlaybackStore(defaults: defaults, blobDirectory: fileBacked ? directory : nil)
        #expect(reopened.progress(for: "tt2000000")?.position == 600)
        print("Background progress save: 1000 entries, \(fileBacked ? "files" : "defaults"), \(elapsed)")
    }
}

private struct TitlePlaybackCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
