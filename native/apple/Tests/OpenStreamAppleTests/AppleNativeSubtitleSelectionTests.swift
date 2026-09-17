import Foundation
import Testing
@testable import OpenStreamApple

/// The rule the AVPlayer route applies to a stream's own subtitle tracks.
///
/// The route used to publish none and select none, so MP4/M4V/MOV/HLS — which
/// on Apple TV is most well-formed content — played with no captions available
/// whether or not an add-on was installed. These cover the selection rule
/// without needing an asset; the track plumbing itself is exercised on device.
@Suite("Native route subtitle selection")
struct AppleNativeSubtitleSelectionTests {
    private let tracks = [
        ApplePlaybackTrack(id: 0, title: "English", language: "en", codec: "sub"),
        ApplePlaybackTrack(id: 1, title: "Spanish", language: "spa", codec: "sub"),
        ApplePlaybackTrack(id: 2, title: "French", language: "fr-FR", codec: "sub"),
    ]

    /// A language preference shortens the menu to that language, in the same
    /// way the demuxing engine already did.
    @Test func aLanguagePreferenceShortensTheMenu() {
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["es"])
        #expect(visible.map(\.id) == [1])
    }

    /// `spa` and `es` are the same language; so are `fr-FR` and `fr`.
    @Test func languageCodeFormsAreTreatedAsOne() {
        #expect(AppleSubtitleTrackFilter.normalized("spa") == "es")
        #expect(AppleSubtitleTrackFilter.normalized("fr-FR") == "fr")
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["fr"]).map(\.id) == [2])
    }

    /// An empty menu is worse than a long one: a stream carrying only
    /// languages the viewer did not ask for still lists them.
    @Test func aStreamWithNoMatchingLanguageStillListsItsTracks() {
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["ja"])
        #expect(visible.map(\.id) == [0, 1, 2])
    }

    /// ...but "list them anyway" must not become "turn one on". Only `.always`
    /// selects a track the viewer did not ask for.
    @Test func onlyAlwaysSelectsALanguageTheViewerDidNotAskFor() {
        #expect(AppleCaptionsPreference.always.autoSelectsAnyTrack)
        #expect(!AppleCaptionsPreference.off.autoSelectsAnyTrack)
    }

    @Test func offSelectsNothing() {
        #expect(AppleCaptionsPreference.off.preferredSubtitleLanguages.isEmpty)
    }
}
