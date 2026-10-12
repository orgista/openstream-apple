import Foundation
import Testing
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import OpenStreamApple

@Suite struct AppleHomeDesignPolicyTests {
    @Test func trailersStayOutOfSystemPlayback() {
        let preview = ApplePlaybackSessionPolicy.trailer
        #expect(preview.audioCategory == .ambient)
        #expect(!preview.publishesNowPlaying)
        #expect(!preview.registersRemoteCommands)
        #expect(ApplePlaybackSessionPolicy.playback.audioCategory == .playback)
        #expect(ApplePlaybackSessionPolicy.playback.publishesNowPlaying)
        #expect(ApplePlaybackSessionPolicy.playback.registersRemoteCommands)
        #expect(!preview.webMediaSessionSuppressionScript.isEmpty)
        #expect(ApplePlaybackSessionPolicy.playback.webMediaSessionSuppressionScript.isEmpty)
    }

    @Test func trailersCannotRestoreLongFormAudioOrUnmuteWebPlayback() throws {
        let preview = ApplePlaybackSessionPolicy.trailer
        #expect(preview.requiresMutedWebPlayback)
        #expect(!preview.shouldRestoreAudioSession(hasPlaybackRequest: true))
        #expect(!preview.shouldRestoreAudioSession(hasPlaybackRequest: false))
        #expect(!ApplePlaybackSessionPolicy.playback.requiresMutedWebPlayback)
        #expect(ApplePlaybackSessionPolicy.playback.shouldRestoreAudioSession(hasPlaybackRequest: true))
        #expect(!ApplePlaybackSessionPolicy.playback.shouldRestoreAudioSession(hasPlaybackRequest: false))

        let embed = try #require(URL(string: "https://fixture.example/embed/trailer?mute=0&playsinline=0"))
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false)
        #expect(html.contains("mute=1"))
        #expect(html.contains("playsinline=1"))
        #expect(!html.contains("mute=0"))
        #expect(!html.contains("playsinline=0"))
        #expect(html.contains("var desiredMuted = true;"))
        #expect(html.contains("desiredMuted = requiresMutedPlayback || Boolean(isMuted);"))
    }

    /// An explicit "Play Trailer" press lifts the muted-only rule
    /// independently of autoplay's `startsMuted` guess, and the two flags
    /// travel together so a caller can never send one without the other.
    @Test func explicitPressAllowsSoundIndependentlyOfAutoplayGuess() throws {
        let embed = try #require(URL(string: "https://fixture.example/embed/trailer"))
        // Autoplay: no press, no sound allowed — muted regardless of the caller's guess.
        let autoplay = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false)
        #expect(autoplay.contains("var requiresMutedPlayback = true;"))
        // Pressed: sound allowed even though the page still opens with the
        // viewer's last mute preference, which may itself be muted.
        let pressed = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true,
                                                        startsMuted: true, allowsSound: true)
        #expect(pressed.contains("var requiresMutedPlayback = false;"))
        #expect(pressed.contains("window.setTrailerAllowsSound = function"))
        #expect(AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: true, isMuted: false)
                == "window.setTrailerAllowsSound(true, false);")
        #expect(AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: false, isMuted: true)
                == "window.setTrailerAllowsSound(false, true);")
    }

    #if canImport(JavaScriptCore)
    @Test func trailerScriptClearsExistingAndRejectsNewMediaSessionHandlers() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var handlers = {play: () => {}, pause: () => {}, seekto: () => {}};
        var events = {};
        var document = {addEventListener: (name, callback) => { events[name] = callback; }};
        var navigator = {mediaSession: {
          metadata: {title: 'Fixture trailer'}, playbackState: 'playing',
          setActionHandler: (name, handler) => {
            if (name === 'stop') throw new Error('Unsupported action');
            handlers[name] = handler;
          },
          setPositionState: () => {}
        }};
        """)
        context.evaluateScript(ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.values(handlers).every(handler => handler === null)")?.toBool() == true)
        context.evaluateScript("""
        navigator.mediaSession.metadata = {title: 'Provider rewrite'};
        navigator.mediaSession.playbackState = 'playing';
        navigator.mediaSession.setActionHandler('play', () => {});
        handlers.seekto = () => {};
        events.play();
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("navigator.mediaSession.metadata === null")?.toBool() == true)
        #expect(context.evaluateScript("navigator.mediaSession.playbackState === 'none'")?.toBool() == true)
        #expect(context.evaluateScript("Object.values(handlers).every(handler => handler === null)")?.toBool() == true)
    }
    #endif

    @Test func manifestCatalogIdentityPreservesSameNamesAndTop10() throws {
        let data = Data(#"""
        {"id":"fixture.aiometadata","name":"AIOMetadata","resources":["catalog"],
         "catalogs":[
           {"id":"popular","type":"movie","name":"Popular Movies"},
           {"id":"popular","type":"series","name":"Popular Movies"},
           {"id":"disney","type":"movie","name":"Top 10 Disney+"}
         ]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: data)
        let source = AppleSource(kind: .stremio, name: manifest.name,
            url: try #require(URL(string: "https://fixture.example/manifest.json")),
            resources: manifest.resources, catalogs: manifest.catalogs)
        let sections = AppleCatalogDiscoveryPolicy.catalogs(for: source).map { catalog in
            AppleCatalogSection(source: source, catalog: catalog, items: [
                AppleCatalogItem(mediaID: "fixture-title", type: catalog.type, name: "Fixture")
            ])
        }
        let visible = AppleCatalogShelfPolicy.visibleSections(sections + sections, activeSourceIDs: [source.id])
        #expect(visible.count == 3)
        #expect(Set(visible.map(\.id)).count == 3)
        // One name over a movie and a series catalog reads by type, so no two
        // rows share a heading (owner, 2026-09-24).
        #expect(visible.map(\.shelfTitle) == ["Popular Movies", "Popular Shows", "Top 10 Disney+"])
        #expect(visible.map { AppleCatalogShelfPolicy.style(for: $0.catalog) }
            == [.poster, .poster, .ranked])
        #expect(AppleCatalogShelfPolicy.visibleSections(sections, activeSourceIDs: []).isEmpty)
    }

    @Test func featuredCatalogsUseLandscapeCardsWithoutRenaming() {
        let catalog = AppleStremioCatalog(type: "movie", id: "featured", name: "Featured Movies")
        #expect(AppleCatalogShelfPolicy.style(for: catalog) == .featured)
        #expect(AppleCatalogShelfPolicy.title(for: catalog) == "Featured Movies")
    }
}
