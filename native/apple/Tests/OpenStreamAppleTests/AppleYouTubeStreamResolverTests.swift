import Foundation
import Testing
@testable import OpenStreamApple

@Suite("YouTube stream resolver")
struct AppleYouTubeStreamResolverTests {
    private typealias R = AppleYouTubeStreamResolver

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func requestUsesTheIOSClientContextWithoutCredentials() throws {
        let request = R.request(videoID: "abc123XYZ_-")
        #expect(request.httpMethod == "POST")
        #expect(request.url == R.endpoint)
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "5")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["videoId"] as? String == "abc123XYZ_-")
        let client = try #require((object["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "IOS")
        #expect(client["clientVersion"] as? String == R.clientVersion)
    }

    @Test func parseReturnsTheHLSManifestForAPlayableVideo() throws {
        let data = json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/x/y.m3u8"],
            "videoDetails": ["title": "Official Trailer"],
        ])
        let stream = try R.parse(data, resolvedAt: Date(timeIntervalSince1970: 100))
        #expect(stream.source == .hls(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/x/y.m3u8")!))
        #expect(stream.title == "Official Trailer")
        #expect(stream.resolvedAt == Date(timeIntervalSince1970: 100))
    }

    // MARK: - Adaptive formats
    //
    // Measured against the real Gentlemen trailer (`wyEOwHrpZH4`) on
    // 2026-09-15: playabilityStatus OK, 27 adaptiveFormats, no hlsManifestUrl.
    // Every trailer had been failing as `noHLS` because only the manifest was
    // looked for.

    private func adaptive(_ formats: [[String: Any]]) -> Data {
        json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["adaptiveFormats": formats],
            "videoDetails": ["title": "Official Trailer"],
        ])
    }

    private func format(_ itag: Int, _ mime: String, height: Int? = nil, bitrate: Int) -> [String: Any] {
        var entry: [String: Any] = [
            "itag": itag,
            "url": "https://rr1---sn-x.googlevideo.com/videoplayback?itag=\(itag)",
            "mimeType": mime,
            "bitrate": bitrate,
        ]
        if let height { entry["height"] = height }
        return entry
    }

    @Test func parseFallsBackToAnAdaptiveH264AndAACPair() throws {
        let data = adaptive([
            format(401, "video/mp4; codecs=\"av01.0.12M.08\"", height: 2160, bitrate: 9_000_000),
            format(313, "video/webm; codecs=\"vp09.00.50.08\"", height: 2160, bitrate: 8_000_000),
            format(137, "video/mp4; codecs=\"avc1.640028\"", height: 1080, bitrate: 4_000_000),
            format(136, "video/mp4; codecs=\"avc1.4D401F\"", height: 720, bitrate: 2_000_000),
            format(251, "audio/webm; codecs=\"opus\"", bitrate: 127_181),
            format(140, "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 130_887),
            format(139, "audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 50_149),
        ])
        let stream = try R.parse(data, resolvedAt: Date())
        // 1080p H.264 over the taller AV1/VP9, and AAC over Opus.
        #expect(stream.source == .adaptive(
            video: URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=137")!,
            audio: URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=140")!
        ))
        #expect(stream.title == "Official Trailer")
    }

    @Test func adaptiveSelectionPrefersTheHLSManifestWhenBothArePresent() throws {
        let data = json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/x/y.m3u8",
                "adaptiveFormats": [
                    format(137, "video/mp4; codecs=\"avc1.640028\"", height: 1080, bitrate: 4_000_000),
                    format(140, "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 130_887),
                ],
            ],
        ])
        let stream = try R.parse(data, resolvedAt: Date())
        #expect(stream.source == .hls(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/x/y.m3u8")!))
    }

    @Test func adaptiveSelectionCapsAt1080pBecauseTheHeroIsNotWorthA4KDecode() {
        let pair = R.selectPair([
            .init(url: URL(string: "https://x/1440")!, mimeType: "video/mp4; codecs=\"avc1.640032\"", height: 1440, bitrate: 6_000_000),
            .init(url: URL(string: "https://x/1080")!, mimeType: "video/mp4; codecs=\"avc1.640028\"", height: 1080, bitrate: 4_000_000),
            .init(url: URL(string: "https://x/aac")!, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", height: nil, bitrate: 130_000),
        ])
        #expect(pair?.video == URL(string: "https://x/1080")!)
    }

    @Test func adaptiveSelectionRejectsCodecsAppleTVCannotDecodeFromAPlainURL() {
        // AV1/VP9 video and Opus audio only — nothing usable, so no pair.
        #expect(R.selectPair([
            .init(url: URL(string: "https://x/av1")!, mimeType: "video/mp4; codecs=\"av01.0.12M.08\"", height: 1080, bitrate: 4_000_000),
            .init(url: URL(string: "https://x/opus")!, mimeType: "audio/webm; codecs=\"opus\"", height: nil, bitrate: 127_000),
        ]) == nil)
    }

    @Test func adaptiveSelectionSkipsFormatsThatNeedSignatureDescrambling() throws {
        let data = json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["adaptiveFormats": [
                ["itag": 137, "signatureCipher": "s=abc&url=https://x/137",
                 "mimeType": "video/mp4; codecs=\"avc1.640028\"", "height": 1080, "bitrate": 4_000_000],
                format(140, "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 130_887),
            ]],
        ])
        #expect(throws: R.Failure.noHLS) { try R.parse(data, resolvedAt: Date()) }
    }

    @Test func parseRejectsUnplayableVideosWithTheirReason() {
        let data = json([
            "playabilityStatus": ["status": "ERROR", "reason": "This video is unavailable"],
        ])
        #expect(throws: R.Failure.unplayable("This video is unavailable")) {
            try R.parse(data, resolvedAt: Date())
        }
    }

    @Test func parseRejectsAResponseWithoutAManifest() {
        let data = json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["formats": []],
        ])
        #expect(throws: R.Failure.noHLS) {
            try R.parse(data, resolvedAt: Date())
        }
    }

    @Test func parseRejectsNonHTTPSManifests() {
        let data = json([
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["hlsManifestUrl": "http://manifest.googlevideo.com/x.m3u8"],
        ])
        #expect(throws: R.Failure.noHLS) {
            try R.parse(data, resolvedAt: Date())
        }
    }

    @Test func parseRejectsNonJSON() {
        #expect(throws: R.Failure.badResponse(200)) {
            try R.parse(Data("<html>".utf8), resolvedAt: Date())
        }
    }
}
