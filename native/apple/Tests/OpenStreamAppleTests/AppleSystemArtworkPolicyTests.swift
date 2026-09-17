import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-16, hovering OpenStream on the tvOS Home screen: "when
/// hovering over the preview doesn't work".
///
/// The shelf published Continue Watching tiles with no artwork because the
/// policy trusted two hosts and the owner's in-progress titles were served by
/// neither. Top Picks looked fine only because Cinemeta serves metahub, which
/// is exactly what made it look like the shelf "sometimes" worked.
@Suite("Artwork allowed on system surfaces")
struct AppleSystemArtworkPolicyTests {
    private func url(_ value: String) -> URL { URL(string: value)! }

    @Test func theHostsTheOwnersOwnLibraryActuallyUsedAreAllowed() {
        // Taken from the media index on the owner's Apple TV.
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://images.justwatch.com/poster/253248954/s332/img")) != nil)
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://api.ratingposterdb.com/t0-free-rpdb/imdb/poster-default/tt13210838.jpg")) != nil)
    }

    @Test func theOriginalTwoHostsStillPass() {
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://image.tmdb.org/t/p/w500/abc.jpg")) != nil)
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://images.metahub.space/poster/medium/tt1/img")) != nil)
    }

    /// Kept from the original policy: a token in a poster URL must not be
    /// handed to a system surface. None of the hosts that actually broke carry
    /// a query, so widening the host rule did not require giving this up.
    @Test func aQueryBearingURLIsStillRefused() {
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://image.tmdb.org/t/p/w500/poster.jpg?token=secret")) == nil)
    }

    @Test func plainHTTPIsRefused() {
        #expect(AppleSystemArtworkPolicy.publicURL(url("http://cdn.example.com/a.jpg")) == nil)
    }

    @Test func credentialsInTheURLAreRefused() {
        #expect(AppleSystemArtworkPolicy.publicURL(
            url("https://user:pass@cdn.example.com/a.jpg")) == nil)
    }

    /// A NAS poster is unreachable from the extension's process and would leak
    /// an internal hostname onto a system surface.
    @Test func privateAndLocalHostsAreRefused() {
        for value in [
            "https://192.168.1.87/poster.jpg",
            "https://10.0.0.4/poster.jpg",
            "https://serverplus.local/poster.jpg",
            "https://nas.internal/poster.jpg",
            "https://localhost/poster.jpg",
            "https://serverplus/poster.jpg",
        ] {
            #expect(AppleSystemArtworkPolicy.publicURL(url(value)) == nil,
                    "\(value) should not reach a system surface")
        }
    }

    @Test func aFileURLIsRefused() {
        #expect(AppleSystemArtworkPolicy.publicURL(url("file:///tmp/a.jpg")) == nil)
    }

    @Test func nilStaysNil() {
        #expect(AppleSystemArtworkPolicy.publicURL(nil) == nil)
    }
}
