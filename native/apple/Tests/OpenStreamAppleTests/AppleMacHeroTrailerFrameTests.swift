import CoreGraphics
import Testing
@testable import OpenStreamApple

/// N30: the Mac hero's trailer comes in over the art with the same frame,
/// crop and darkness, and the fade over the art is lighter than it was.
@Suite("Mac hero: art to trailer without a jump")
struct AppleMacHeroTrailerFrameTests {
    private static let heroes: [CGSize] = [
        CGSize(width: 1_440, height: 675), CGSize(width: 1_920, height: 680),
        CGSize(width: 1_000, height: 560), CGSize(width: 900, height: 675),
    ]

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    @Test("A 16:9 trailer fills the hero exactly as a 16:9 still does", arguments: heroes)
    func trailerMatchesTheArt(hero: CGSize) {
        let video = AppleTrailerPreviewLayout.coverFrame(in: hero)
        let art = AppleTrailerPreviewLayout.aspectFillFrame(of: CGSize(width: 1_920, height: 1_080), in: hero)
        #expect(isClose(video, art))
        #expect(abs(video.width / video.height - 16.0 / 9.0) < 0.0001)
        // Covers the hero, centred.
        #expect(video.minX <= 0.001 && video.maxX >= hero.width - 0.001)
        #expect(video.minY <= 0.001 && video.maxY >= hero.height - 0.001)
        #expect(abs(video.midX - hero.width / 2) < 0.001 && abs(video.midY - hero.height / 2) < 0.001)
    }

    @Test("Art and trailer draw the same fade, so nothing darkens when the video comes in",
          arguments: [AppleHeroArtTone.dark, .unknown])
    func sameFadeForArtAndVideo(tone: AppleHeroArtTone) {
        let art = AppleHeroScrim.wide(tone: tone, videoIsShowing: false, copyTrailing: 0.37)
        let video = AppleHeroScrim.wide(tone: tone, videoIsShowing: true, copyTrailing: 0.37)
        #expect(art == video)
    }

    @Test("The default fade is lighter: at most 60 % at the edge, clear by half the width")
    func defaultFadeIsLighter() throws {
        let leading = AppleMacHeroFade.leading
        #expect(try #require(leading.first).opacity <= 0.6)
        #expect(try #require(leading.last).opacity == 0)
        #expect(try #require(leading.last).location <= 0.5)
        #expect(leading.allSatisfy { $0.opacity <= 0.6 })
        // Clearly lighter than the old 85 %-to-30 % fade across the copy column.
        #expect(AppleHeroScrim.opacity(of: leading, at: 0.3) < 0.4)
        #expect(AppleHeroScrim.opacity(of: AppleMacHeroFade.bottom, at: 0) == 1)
    }

    @Test("Bright art keeps the approved fade and existing copy shadow")
    func brightArtKeepsApprovedFade() {
        let bright = AppleHeroScrim.wide(tone: .bright, videoIsShowing: false, copyTrailing: 0.37)
        #expect(bright.leading == AppleMacHeroFade.leading)
        #expect(bright.bottom == AppleMacHeroFade.bottom)
        #expect(bright.copyShadow == AppleHeroScrim.brightCopyShadow)
    }
}

/// N22b/N30: a hero with nothing to play and no trailer says Details — and
/// never waits for its trailer lookups forever with only the "+" showing.
@Suite("Hero button: Details when nothing plays")
struct AppleHeroDetailsFallbackTests {
    @Test("A found trailer is Play Trailer whatever the lookups")
    func trailerFound() {
        #expect(AppleTitlePagePolicy.trailerAvailability(hasTrailer: true, lookupsAnswered: false,
                                                         patienceElapsed: false) == .available)
    }

    @Test("Still looking, within the patience: held back")
    func stillLooking() {
        #expect(AppleTitlePagePolicy.trailerAvailability(hasTrailer: false, lookupsAnswered: false,
                                                         patienceElapsed: false) == .pending)
    }

    @Test("Answered or out of patience with no trailer: none, so the button is Details",
          arguments: [(true, false), (false, true), (true, true)])
    func noTrailerIsDetails(answered: Bool, elapsed: Bool) {
        let availability = AppleTitlePagePolicy.trailerAvailability(
            hasTrailer: false, lookupsAnswered: answered, patienceElapsed: elapsed)
        #expect(availability == .none)
        let action = AppleTitlePagePolicy.heroPrimaryAction(
            type: "series", progress: nil, selectedEpisode: nil, isPlayable: false, trailer: availability)
        #expect(action == .details)
        #expect(!AppleTitlePagePolicy.HeroButton(action: action).isHidden)
    }

    @Test("The patience is short")
    func patienceIsShort() {
        #expect(AppleTitlePagePolicy.heroTrailerLookupPatience <= .seconds(6))
    }
}
