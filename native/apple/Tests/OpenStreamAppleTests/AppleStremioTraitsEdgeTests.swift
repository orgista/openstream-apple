import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases for `AppleStremioCandidateRanking.traits(of:)`, `playbackClass`
/// and `isPlayable` that `AppleStreamQualityTests` does not already cover:
/// codec-name spelling variants, container detection from the URL path when
/// there is no filename, and dynamic-range playability by device.
struct AppleStremioTraitsEdgeTests {
    static func candidate(_ name: String, url: String? = nil) -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: name, sourceURL: URL(string: url ?? "https://fixture.example/\(name)")!,
                                          filename: url == nil ? name : nil)
    }

    @Test func hevcDetectionIsCaseInsensitiveAcrossSpellings() {
        for name in ["Film.HEVC.mp4", "Film.X265.mp4", "Film.H.265.mp4"] {
            #expect(AppleStremioCandidateRanking.traits(of: Self.candidate(name)).video == .hevc, "\(name)")
        }
    }

    @Test func dolbyVisionSpelledOutMatchesLikeDV() {
        let short = AppleStremioCandidateRanking.traits(of: Self.candidate("Feature.2160p.DV.HEVC.mkv"))
        let long = AppleStremioCandidateRanking.traits(of: Self.candidate("Title.2160p.Dolby.Vision.HEVC.mkv"))
        #expect(short.dynamicRange == .dolbyVision(hasHDRFallback: false))
        #expect(long.dynamicRange == .dolbyVision(hasHDRFallback: false))
    }

    @Test func dolbyVisionWithHDR10FallbackIsRecorded() {
        let traits = AppleStremioCandidateRanking.traits(of: Self.candidate("Feature.2160p.DV.HDR10.HEVC.mkv"))
        #expect(traits.dynamicRange == .dolbyVision(hasHDRFallback: true))
    }

    @Test func av1IsRecordedAndNeverDirectPlay() {
        let traits = AppleStremioCandidateRanking.traits(of: Self.candidate("Feature.2160p.AV1.AAC.mkv"))
        #expect(traits.video == .av1)
        #expect(AppleStremioCandidateRanking.playbackClass(traits) == .other)
    }

    @Test func containerComesFromTheURLPathWhenThereIsNoFilename() {
        let mkv = AppleStremioCandidateRanking.traits(of: Self.candidate("mkv", url: "https://fixture.example/stream/movie.mkv"))
        let mp4 = AppleStremioCandidateRanking.traits(of: Self.candidate("mp4", url: "https://fixture.example/stream/movie.mp4"))
        let ts = AppleStremioCandidateRanking.traits(of: Self.candidate("ts", url: "https://fixture.example/stream/movie.ts"))
        #expect(mkv.container == .matroska)
        #expect(mp4.container == .mp4)
        #expect(ts.container == .transportStream)
    }

    @Test func audioCodecsMapToPlayerSupport() {
        let trueHD = AppleStremioCandidateRanking.traits(of: Self.candidate("Film.TrueHD.mkv"))
        let dts = AppleStremioCandidateRanking.traits(of: Self.candidate("Film.DTS.mkv"))
        let aac = AppleStremioCandidateRanking.traits(of: Self.candidate("Film.AAC.mp4"))
        #expect(trueHD.audio == .needsTranscode)
        #expect(dts.audio == .needsTranscode)
        #expect(aac.audio == .avPlayerSafe)
    }

    @Test func aNameWithNoHintsIsAllUnknown() {
        let traits = AppleStremioCandidateRanking.traits(of: Self.candidate("Movie"))
        #expect(traits.container == .unknown)
        #expect(traits.video == .unknown)
        #expect(traits.audio == .unknown)
        #expect(traits.dynamicRange == .sdr)
        #expect(traits.tier == nil)
    }

    @Test func dolbyVisionWithoutFallbackIsUnplayableOnlyWithoutDolbyVisionSupport() {
        let traits = AppleStremioCandidateRanking.traits(of: Self.candidate("Feature.2160p.DV.HEVC.mkv"))
        let withoutSupport = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: false)
        let withSupport = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: true)
        #expect(AppleStremioCandidateRanking.isPlayable(traits, on: withoutSupport) == false)
        #expect(AppleStremioCandidateRanking.isPlayable(traits, on: withSupport) == true)
    }

    @Test func everythingElseIsPlayableRegardlessOfDeviceCapabilities() {
        let hdr = AppleStremioCandidateRanking.traits(of: Self.candidate("Film.1080p.HDR.HEVC.mp4"))
        let sdr = AppleStremioCandidateRanking.traits(of: Self.candidate("Film.720p.x264.mp4"))
        let noHDRNoDolbyVision = AppleStreamDeviceCapabilities(supportsHDR: false, supportsDolbyVision: false)
        #expect(AppleStremioCandidateRanking.isPlayable(hdr, on: noHDRNoDolbyVision) == true)
        #expect(AppleStremioCandidateRanking.isPlayable(sdr, on: noHDRNoDolbyVision) == true)
    }
}
