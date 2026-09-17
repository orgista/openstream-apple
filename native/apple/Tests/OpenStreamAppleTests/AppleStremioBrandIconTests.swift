import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Stremio brand icon fallback")
struct AppleStremioBrandIconTests {
    @Test func cinemetaGetsTheStremioMark() {
        let url = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!
        #expect(AppleStremioBrandIcon.fallbackURL(kind: .stremio, manifestURL: url) == AppleStremioBrandIcon.url)
    }

    @Test func theApexDomainCountsTooAndSoDoesTheAlias() {
        #expect(AppleStremioBrandIcon.isStremioHosted(URL(string: "https://strem.io/manifest.json")))
        #expect(AppleStremioBrandIcon.isStremioHosted(URL(string: "https://opensubtitles-v3.strem.io/manifest.json")))
        #expect(AppleStremioBrandIcon.isStremioHosted(URL(string: "https://app.stremio.com/manifest.json")))
    }

    /// A look-alike host must not borrow the mark.
    @Test func lookAlikeHostsAreRejected() {
        #expect(!AppleStremioBrandIcon.isStremioHosted(URL(string: "https://notstrem.io/manifest.json")))
        #expect(!AppleStremioBrandIcon.isStremioHosted(URL(string: "https://strem.io.example.com/manifest.json")))
        #expect(!AppleStremioBrandIcon.isStremioHosted(URL(string: "https://torrentio.strem.fun/manifest.json")))
        #expect(!AppleStremioBrandIcon.isStremioHosted(nil))
    }

    /// Torrentio is a real add-on on a non-Stremio host: it keeps its own logo
    /// and, failing that, its own monogram.
    @Test func addOnsOnOtherHostsKeepTheirOwnFallback() {
        let url = URL(string: "https://torrentio.strem.fun/manifest.json")!
        #expect(AppleStremioBrandIcon.fallbackURL(kind: .stremio, manifestURL: url) == nil)
    }

    /// An IPTV playlist or share that happened to sit on strem.io is not an
    /// add-on and must not be branded as one.
    @Test func onlyAddOnsQualify() {
        let url = URL(string: "https://strem.io/playlist.m3u")!
        #expect(AppleStremioBrandIcon.fallbackURL(kind: .liveTV, manifestURL: url) == nil)
        #expect(AppleStremioBrandIcon.fallbackURL(kind: .nas, manifestURL: url) == nil)
        #expect(AppleStremioBrandIcon.fallbackURL(kind: .library, manifestURL: url) == nil)
    }
}
