import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases `AppleLiveStreamRoutePolicyTests` skips: scheme and extension
/// casing, a query string sitting after the extension, the second HLS
/// extension (`.m3u`), a URL with no extension at all, an untyped `.other`
/// probe verdict, and non-HTTP schemes.
@Suite struct AppleLiveStreamRoutePolicyEdgeTests {
    @Test func needsProbeAcceptsAnUppercaseHTTPSScheme() {
        let url = URL(string: "HTTPS://fixture.example/895")!
        #expect(AppleLiveStreamRoutePolicy.needsProbe(url))
    }

    @Test func needsProbeTreatsExtensionsCaseInsensitively() {
        let url = URL(string: "https://fixture.example/live/tf1.M3U8")!
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(url))
    }

    @Test func needsProbeIgnoresNonHTTPSchemesEvenWithAnUnrecognisedExtension() {
        let url = URL(string: "ftp://fixture.example/895")!
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(url))
    }

    @Test func needsProbeIsUnaffectedByAQueryStringOrFragmentAfterTheExtension() {
        let url = URL(string: "https://fixture.example/live/tf1.m3u8?token=abc#live")!
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(url))
    }

    /// `hlsExtensions` holds both `m3u8` and the bare `m3u` playlist suffix;
    /// the existing tests only ever exercise the former.
    @Test func bareM3UPlaylistsRouteLikeM3U8() {
        let url = URL(string: "https://fixture.example/live/tf1.m3u")!
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(url))
        #expect(AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: url, probedKind: nil))
    }

    /// The existing tests only try `.rawMPEGTransportStream` as the probe
    /// verdict that beats an HLS-looking extension; `.other` takes the same
    /// branch and must win too.
    @Test func aProbedOtherVerdictOverridesAnHLSLookingExtension() {
        let hls = URL(string: "https://fixture.example/live/tf1.m3u8")!
        #expect(!AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: hls, probedKind: .other))
    }

    @Test func aTrailingDotWithNoExtensionStillNeedsAProbe() {
        let url = URL(string: "https://fixture.example/live/895.")!
        #expect(AppleLiveStreamRoutePolicy.needsProbe(url))
    }

    /// A local file URL never needs a probe, even carrying an
    /// HLS-looking extension: the scheme guard rejects it before the
    /// extension is ever consulted.
    @Test func aLocalFileURLNeverNeedsAProbe() {
        let url = URL(string: "file:///local/foo.m3u8")!
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(url))
    }
}
