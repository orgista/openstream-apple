import Foundation
import Testing
@testable import OpenStreamApple

/// The player's CC key. Owner 2026-09-20: one tap on, one tap off, for the one
/// preferred-language track the subtitles picker was already reduced to.
@Suite("Captions toggle")
struct AppleCaptionsToggleTests {
    private let english = ApplePlaybackTrack(id: 3, title: "English", language: "eng")
    private let french = ApplePlaybackTrack(id: 7, title: "French", language: "fra")

    @Test func theKeyTurnsOnThePreferredTrack() {
        #expect(AppleCaptionsToggle.nextSelection(selected: nil, visible: [english]) == 3)
    }

    @Test func theSameKeyTurnsItOff() {
        #expect(AppleCaptionsToggle.nextSelection(selected: 3, visible: [english]) == nil)
    }

    /// The picker is one option by design, but a viewer with no language
    /// preference still sees the file's own list — and can pick something the
    /// key would not have chosen. Captions are on screen either way, so the key
    /// reads on and its next tap clears them.
    @Test func aTrackChosenInTheMenuStillReadsAsOn() {
        #expect(AppleCaptionsToggle.isOn(selected: 7))
        #expect(AppleCaptionsToggle.nextSelection(selected: 7, visible: [english]) == nil)
    }

    /// Turning on always goes back to the preferred track; the menu is where a
    /// different one is chosen.
    @Test func turningOnAfterAMenuChoiceReturnsToThePreferredTrack() {
        let off = AppleCaptionsToggle.nextSelection(selected: french.id, visible: [english])
        #expect(off == nil)
        #expect(AppleCaptionsToggle.nextSelection(selected: off, visible: [english]) == 3)
    }

    @Test func aStreamWithNoTrackInTheViewersLanguageGetsNoKey() {
        #expect(AppleCaptionsToggle.isAvailable(visible: []) == false)
        #expect(AppleCaptionsToggle.trackToEnable(visible: []) == nil)
        #expect(AppleCaptionsToggle.nextSelection(selected: nil, visible: []) == nil)
    }

    @Test func theKeyIsDrawnWhenThereIsATrackToTurnOn() {
        #expect(AppleCaptionsToggle.isAvailable(visible: [english]))
    }

    /// `visible` is `AppleSubtitleTrackFilter`'s output, so the key and the
    /// menu can never disagree about which track "the preferred one" is.
    @Test func theKeyUsesTheSameTrackTheMenuOffers() {
        let visible = AppleSubtitleTrackFilter.visible(
            [french, english], preferredLanguages: ["en"], isExplicitChoice: true
        )
        #expect(visible.map(\.id) == [3])
        #expect(AppleCaptionsToggle.trackToEnable(visible: visible) == 3)
    }
}
