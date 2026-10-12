import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-23: "remove trailers from Apple TV and add them to Mac".
@Suite("Trailers by platform")
struct AppleTrailerPlatformPolicyTests {
    private static let saved = AppleStremioEpisode(id: "tt0903747:1:3", title: "", season: 1, episode: 3, releaseInfo: nil)

    @Test func onlyTheAppleTVGoesWithoutTrailers() {
        #expect(!AppleTitlePagePolicy.offersTrailers(on: .tvOS))
        #expect(AppleTitlePagePolicy.offersTrailers(on: .macOS))
        #expect(AppleTitlePagePolicy.offersTrailers(on: .iOS))
        #expect(AppleTitlePagePolicy.offersTrailers(on: .visionOS))
    }

    @Test(arguments: [
        (type: "movie", progress: nil as ApplePlaybackProgress?, isPlayable: false),
        (type: "movie", progress: nil, isPlayable: true),
        (type: "movie", progress: ApplePlaybackProgress(position: 1_200, duration: 6_000), isPlayable: true),
        (type: "series", progress: nil, isPlayable: false),
        (type: "series", progress: ApplePlaybackProgress(position: 600, duration: 3_000, partID: saved.id), isPlayable: true),
    ])
    func theAppleTVNeverOffersPlayTrailer(type: String, progress: ApplePlaybackProgress?, isPlayable: Bool) {
        for hasTrailer in [false, true] {
            let action = AppleTitlePagePolicy.primaryAction(
                type: type, progress: progress, selectedEpisode: Self.saved,
                isPlayable: isPlayable, hasTrailer: hasTrailer, platform: .tvOS)
            #expect(action != .playTrailer)
        }
    }

    @Test func nothingPlayableOnTheAppleTVStillSaysPlay() {
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: false, hasTrailer: true,
            platform: .tvOS) == .play)
    }

    @Test func theMacKeepsPlayTrailerWhenNothingElseCanPlay() {
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: false, hasTrailer: true,
            platform: .macOS) == .playTrailer)
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: true, hasTrailer: true,
            platform: .macOS) == .play)
    }

    @Test func theIPhoneAndVisionProAreUnchanged() {
        for platform in [AppleUIPlatform.iOS, .visionOS] {
            #expect(AppleTitlePagePolicy.primaryAction(
                type: "series", progress: nil, selectedEpisode: nil, isPlayable: false, hasTrailer: true,
                platform: platform) == .playTrailer)
        }
    }
}
