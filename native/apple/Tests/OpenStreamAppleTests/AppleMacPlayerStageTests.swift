import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// The Mac player takes over the window it was opened from.
@MainActor
struct AppleMacPlayerStageTests {
    private nonisolated static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/OpenStreamApple")

    // MARK: Presentation

    @Test func theMacPresentsInTheWindowAndNotASheet() {
        #if os(macOS) || os(visionOS)
        #expect(AppleStremioPlayerPresentationStyle.current == .windowStage)
        #endif
    }

    /// Every page that opens a player hands it to the one modifier, and only
    /// the stages (Mac, Vision Pro) and the cover (iOS, tvOS) build the
    /// player view — so no entry point can grow a presentation of its own.
    ///
    /// `nonisolated`: it reads every source file, which on the SMB share can
    /// take seconds, and on the main actor that stalled the other tests'
    /// main-actor work until their request timeouts and deadlines ran out.
    @Test nonisolated func everyEntryPointUsesTheOnePresentationPath() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path)
            .filter { $0.hasSuffix(".swift") }
        var builders: Set<String> = []
        var presenters: Set<String> = []
        for file in files {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            if text.contains("AppleStremioPlayerView(presentation:") { builders.insert(file) }
            if text.contains("AppleStremioPlayerPresentationModifier(presentation:") { presenters.insert(file) }
        }
        #expect(builders == ["AppleDiscoverView.swift", "AppleMacPlayerStage.swift", "AppleVisionPlayerStage.swift"])
        // Title pages (Discover, Library, media servers), Add Files, Live.
        #expect(presenters.isSuperset(of: ["AppleDiscoverView.swift", "AppleSourcesSettingsView.swift",
                                           "AppleMediaSourceViews.swift"]))
        let discover = try String(contentsOf: Self.sources.appendingPathComponent("AppleDiscoverView.swift"),
                                  encoding: .utf8)
        let modifier = try #require(discover.range(of: "struct AppleMediaPlayerPresentationModifier"))
        let macBranch = discover[modifier.lowerBound...].prefix(1_200)
        #expect(macBranch.contains("AppleMacPlayerStagePresenter"))
        #expect(macBranch.contains("content.sheet(") == false)
        #expect(macBranch.contains("minWidth") == false)
        // Vision Pro: in the app's window too, never a second "Player" window.
        #expect(macBranch.contains("AppleVisionPlayerStagePresenter"))
        #expect(macBranch.contains("openWindow") == false)
        let scenes = try files.filter {
            try String(contentsOf: Self.sources.appendingPathComponent($0), encoding: .utf8)
                .contains("WindowGroup(\"Player\"")
        }
        #expect(scenes.isEmpty)
    }

    // MARK: Frame

    @Test(arguments: [CGSize(width: 1280, height: 860), CGSize(width: 3440, height: 1440),
                      CGSize(width: 2560, height: 1080), CGSize(width: 900, height: 1400)])
    func thePictureIsTheWholeContainer(_ container: CGSize) {
        #expect(AppleMacPlayerFramePolicy.playerFrame(in: container) == CGRect(origin: .zero, size: container))
    }

    @Test func gravityFollowsZoomToFill() {
        #expect(AppleMacPlayerFramePolicy.videoGravity(zoomToFill: false) == .resizeAspect)
        #expect(AppleMacPlayerFramePolicy.videoGravity(zoomToFill: true) == .resizeAspectFill)
        #expect(AppleMacCommandCenter().zoomToFill == false)
    }

    // MARK: Keys

    @Test func escapeAndCommandWCloseThePlayer() {
        #expect(AppleMacPlayerKeyPolicy.closesPlayer(.escape, windowHasSheet: false))
        #expect(AppleMacPlayerKeyPolicy.closesPlayer(.commandW, windowHasSheet: false))
        #expect(AppleMacPlayerKeyPolicy.closesPlayer(.other, windowHasSheet: false) == false)
    }

    @Test func aSheetOverThePlayerKeepsItsOwnEscape() {
        #expect(AppleMacPlayerKeyPolicy.closesPlayer(.escape, windowHasSheet: true) == false)
        #expect(AppleMacPlayerKeyPolicy.closesPlayer(.commandW, windowHasSheet: true) == false)
    }

    #if os(macOS)
    @Test func keysAreReadFromTheEvent() {
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 53, modifiers: [], characters: "\u{1b}") == .escape)
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 13, modifiers: .command, characters: "w") == .commandW)
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 13, modifiers: [.command, .shift], characters: "W") == .other)
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 13, modifiers: [.command, .option], characters: "w") == .other)
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 53, modifiers: .command, characters: "\u{1b}") == .other)
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 49, modifiers: [], characters: " ") == .other)
        // Caps Lock and the function key do not turn ⌘W into another command.
        #expect(AppleMacPlayerKeyPolicy.key(keyCode: 13, modifiers: [.command, .capsLock], characters: "w") == .commandW)
    }

    // MARK: Stage

    @Test func closingTellsThePageAndPutsTheMenuBack() {
        let commands = AppleMacCommandCenter()
        let stage = AppleMacPlayerStage(commands: commands)
        var closed = 0
        let first = presentation()
        stage.present(first) { closed += 1 }
        #expect(stage.presentation?.id == first.id)
        #expect(commands.isPlayerOnStage)
        stage.dismiss()
        #expect(stage.presentation == nil)
        #expect(closed == 1)
        #expect(commands.isPlayerOnStage == false)
        stage.dismiss()
        #expect(closed == 1)
    }

    /// Next episode: the page clears the old presentation and sets a new
    /// one. A stale clear must not take the new player down.
    @Test func aStaleDismissCannotCloseTheNextPlayer() {
        let stage = AppleMacPlayerStage(commands: AppleMacCommandCenter())
        var closedFirst = 0
        var closedSecond = 0
        let first = presentation()
        let second = presentation()
        stage.present(first) { closedFirst += 1 }
        stage.present(second) { closedSecond += 1 }
        #expect(closedFirst == 1)
        stage.dismiss(id: first.id)
        #expect(stage.presentation?.id == second.id)
        #expect(closedSecond == 0)
        stage.dismiss(id: second.id)
        #expect(stage.presentation == nil)
        #expect(closedSecond == 1)
    }

    @Test func presentingTheSamePlayerTwiceIsOnePresentation() {
        let stage = AppleMacPlayerStage(commands: AppleMacCommandCenter())
        var closed = 0
        let only = presentation()
        stage.present(only) { closed += 1 }
        stage.present(only) { closed += 1 }
        #expect(closed == 0)
        stage.dismiss()
        #expect(closed == 1)
    }

    private func presentation() -> AppleStremioPlayerPresentation {
        let name = "openstream.tests.stage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let settings = AppleSettingsStore(defaults: defaults, keychain: StageTestCredentials())
        settings.playbackEngine = .native
        return AppleStremioPlayerPresentation(
            request: ApplePlaybackRequest(url: URL(string: "https://fixture.example/film.mp4")!,
                                          mediaID: "stage-test", sourceKind: .files),
            settings: settings)
    }
    #endif

    // MARK: Captions menu

    @Test func theAppCaptionsMenuShowsOnlyForTracksAVKitCannotReach() {
        let native = [ApplePlaybackTrack(id: 0, title: "English", language: "en", codec: "sub"),
                      ApplePlaybackTrack(id: 1, title: "French", language: "fr", codec: "sub")]
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: native, stockPlayerListsCaptions: true) == false)
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: [], stockPlayerListsCaptions: true) == false)
        let sidecar = ApplePlaybackTrack(id: 1_000_000, title: "Add-on", language: "en", codec: "srt")
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: native + [sidecar], stockPlayerListsCaptions: true))
        let bitmap = ApplePlaybackTrack(id: 4, title: "PGS", language: "en", codec: "hdmv_pgs_subtitle")
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: [bitmap], stockPlayerListsCaptions: true))
    }

    /// The default engine's loopback item carries no legible renditions on
    /// the Mac, so AVKit has no CC button and the app's menu is the only one.
    @Test func theAppCaptionsMenuIsTheOnlyOneWhenAVKitListsNothing() {
        let embedded = [ApplePlaybackTrack(id: 2, title: "English", language: "eng", codec: "subrip")]
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: embedded, stockPlayerListsCaptions: false))
        #expect(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: [], stockPlayerListsCaptions: false) == false)
    }
}

private struct StageTestCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
