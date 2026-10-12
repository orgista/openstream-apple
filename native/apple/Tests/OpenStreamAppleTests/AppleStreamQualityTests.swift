import Foundation
import Testing
@testable import OpenStreamApple

/// The quality picker's rows and the backend's pick for each (owner
/// 2026-09-24: "someone can select 4K, 1080, 720 and the backend should
/// handle where it can find the best type of source for that device, i.e.
/// mp4 if available, if not the next best").
struct AppleStreamQualityTests {
    static func candidate(_ name: String) -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: name, sourceURL: URL(string: "https://fixture.example/\(name)")!,
                                          filename: name)
    }

    /// One film as a busy set of add-ons returns it, in resolver order.
    static let sample: [AppleStremioHTTPPlaybackCandidate] = [
        "Film.2023.2160p.DV.HDR10.HEVC.DDP5.1.mkv",
        "Film.2023.2160p.DV.HEVC.TrueHD.Atmos.mkv",
        "Film.2023.2160p.HDR.HEVC.EAC3.mp4",
        "Film.2023.2160p.x265.AAC.mp4",
        "Film.2023.1080p.BluRay.x264.DTS.mkv",
        "Film.2023.1080p.WEB.H264.AAC.mp4",
        "Film.2023.1080p.WEB.H265.EAC3.mkv",
        "Film.2023.720p.x264.AAC.mkv",
        "Film.2023.480p.XviD.MP3.avi",
        "Film.2023.WEBRip.x264.mkv",
    ].map(candidate)

    static let dolbyVisionTV = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: true)
    static let hdrMac = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: false)
    static let sdrScreen = AppleStreamDeviceCapabilities(supportsHDR: false, supportsDolbyVision: false)
    static let phone = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: true, automaticTierCap: .fullHD)

    static func names(_ list: [AppleStremioHTTPPlaybackCandidate]) -> [String] { list.map { $0.filename ?? "" } }

    // MARK: Tiers

    @Test func oneRowPerResolutionWithSDOnlyWhenNothingBetter() {
        #expect(AppleStremioCandidateRanking.qualityTiers(Self.sample, device: Self.hdrMac).map(\.title)
            == ["4K", "1080p", "720p"])
        let low = ["Film.480p.x264.mp4", "Film.WEBRip.mkv"].map(Self.candidate)
        #expect(AppleStremioCandidateRanking.qualityTiers(low, device: Self.hdrMac) == [.sd])
        #expect(AppleStremioCandidateRanking.qualityTiers([Self.candidate("Film.WEBRip.mkv")], device: Self.hdrMac).isEmpty)
        #expect(AppleStremioCandidateRanking.qualityTiers([], device: Self.hdrMac).isEmpty)
    }

    @Test func tierTitlesNameOnlyThePicture() {
        for tier in AppleStreamQualityTier.allCases {
            #expect(["SD", "720p", "1080p", "4K"].contains(tier.title))
        }
        #expect(AppleStreamQualityTier(resolution: 1440) == .fullHD)
        #expect(AppleStreamQualityTier(resolution: 4320) == .uhd)
        #expect(AppleStreamQualityTier(resolution: 576) == .sd)
        #expect(AppleStreamQualityTier(resolution: 0) == nil)
    }

    /// A Dolby Vision release with no HDR10 base layer decides whether 4K is
    /// offered at all, and only by what this display can show.
    @Test func dolbyVisionOnlyPopulatesATierOnADolbyVisionDisplay() {
        let dvOnly = [Self.candidate("Film.2160p.DV.HEVC.mkv"), Self.candidate("Film.1080p.x264.mp4")]
        #expect(AppleStremioCandidateRanking.qualityTiers(dvOnly, device: Self.dolbyVisionTV) == [.uhd, .fullHD])
        #expect(AppleStremioCandidateRanking.qualityTiers(dvOnly, device: Self.hdrMac) == [.fullHD])
        let withBaseLayer = [Self.candidate("Film.2160p.DV.HDR10.HEVC.mkv")]
        #expect(AppleStremioCandidateRanking.qualityTiers(withBaseLayer, device: Self.sdrScreen) == [.uhd])
    }

    // MARK: Ranking within a tier

    @Test func directPlayMP4BeatsRemuxBeatsTranscode() {
        let order = Self.names(AppleStremioCandidateRanking.playbackOrder(
            Self.sample, choice: .tier(.fullHD), device: Self.hdrMac))
        #expect(Array(order.prefix(3)) == ["Film.2023.1080p.WEB.H264.AAC.mp4",
                                           "Film.2023.1080p.WEB.H265.EAC3.mkv",
                                           "Film.2023.1080p.BluRay.x264.DTS.mkv"])
    }

    @Test func dynamicRangeFollowsTheDisplay() {
        let hdr = Self.names(AppleStremioCandidateRanking.playbackOrder(
            Self.sample, choice: .tier(.uhd), device: Self.hdrMac))
        #expect(Array(hdr.prefix(3)) == ["Film.2023.2160p.HDR.HEVC.EAC3.mp4",
                                         "Film.2023.2160p.x265.AAC.mp4",
                                         "Film.2023.2160p.DV.HDR10.HEVC.DDP5.1.mkv"])
        let sdr = Self.names(AppleStremioCandidateRanking.playbackOrder(
            Self.sample, choice: .tier(.uhd), device: Self.sdrScreen))
        #expect(sdr.first == "Film.2023.2160p.x265.AAC.mp4")
        // Dolby Vision without a base layer cannot show properly here: last of all.
        #expect(sdr.last == "Film.2023.2160p.DV.HEVC.TrueHD.Atmos.mkv")
    }

    /// Same container class, both HDR-capable: the Dolby Vision release wins
    /// on a Dolby Vision display, the HDR10 one elsewhere.
    @Test func dolbyVisionIsPreferredOnlyWhereItShows() {
        let pair = ["Film.2160p.HDR10.HEVC.EAC3.mkv", "Film.2160p.DV.HEVC.EAC3.mkv"].map(Self.candidate)
        #expect(Self.names(AppleStremioCandidateRanking.playbackOrder(pair, choice: .tier(.uhd), device: Self.dolbyVisionTV)).first
            == "Film.2160p.DV.HEVC.EAC3.mkv")
        #expect(Self.names(AppleStremioCandidateRanking.playbackOrder(pair, choice: .tier(.uhd), device: Self.hdrMac)).first
            == "Film.2160p.HDR10.HEVC.EAC3.mkv")
    }

    // MARK: Automatic and fallback order

    @Test func automaticTakesTheBestTierTheDeviceIsCappedAt() {
        let tv = Self.names(AppleStremioCandidateRanking.playbackOrder(Self.sample, choice: .automatic, device: Self.dolbyVisionTV))
        #expect(tv.first == "Film.2023.2160p.HDR.HEVC.EAC3.mp4")
        let phone = Self.names(AppleStremioCandidateRanking.playbackOrder(Self.sample, choice: .automatic, device: Self.phone))
        #expect(phone.first == "Film.2023.1080p.WEB.H264.AAC.mp4")
        // Below the cap first, then an unnamed resolution, then above the cap.
        let tiers = phone.map { AppleStremioCandidateRanking.traits(of: Self.candidate($0)).tier }
        #expect(tiers == [.fullHD, .fullHD, .fullHD, .hd, .sd, nil, .uhd, .uhd, .uhd, .uhd])
    }

    @Test func aPickedTierFallsToTheNearestPictureLowerFirst() {
        let order = AppleStremioCandidateRanking.playbackOrder(Self.sample, choice: .tier(.hd), device: Self.hdrMac)
        let tiers = order.map { AppleStremioCandidateRanking.traits(of: $0).tier }
        #expect(tiers.first == .hd)
        #expect(Array(tiers.prefix(5)) == [.hd, .sd, .fullHD, .fullHD, .fullHD])
        #expect(order.count == Self.sample.count, "a tier's order still holds every fallback")
    }

    @Test func aReleaseNamingAnotherEpisodeStaysBehind() {
        let list = ["Show.S01E02.2160p.HEVC.mp4", "Show.S01E01.720p.x264.mkv"].map(Self.candidate)
        let order = AppleStremioCandidateRanking.playbackOrder(list, choice: .tier(.uhd), device: Self.hdrMac,
                                                               episode: (season: 1, episode: 1))
        #expect(Self.names(order) == ["Show.S01E01.720p.x264.mkv", "Show.S01E02.2160p.HEVC.mp4"])
    }

    @Test func tiesKeepTheResolversOrder() {
        let twins = ["A.1080p.x264.AAC.mp4", "B.1080p.x264.AAC.mp4"].map(Self.candidate)
        #expect(Self.names(AppleStremioCandidateRanking.playbackOrder(twins, choice: .automatic, device: Self.hdrMac))
            == ["A.1080p.x264.AAC.mp4", "B.1080p.x264.AAC.mp4"])
    }

    // MARK: Traits

    @Test func traitsReadTheReleaseName() {
        let dv = AppleStremioCandidateRanking.traits(of: Self.sample[0])
        #expect(dv.container == .matroska && dv.video == .hevc && dv.audio == .avPlayerSafe)
        #expect(dv.dynamicRange == .dolbyVision(hasHDRFallback: true) && dv.tier == .uhd)
        let mp4 = AppleStremioCandidateRanking.traits(of: Self.sample[5])
        #expect(AppleStremioCandidateRanking.playbackClass(mp4) == .directPlay)
        #expect(AppleStremioCandidateRanking.playbackClass(AppleStremioCandidateRanking.traits(of: Self.sample[4])) == .other)
        let gateway = AppleStremioHTTPPlaybackCandidate(title: "Film 1080p", sourceURL: URL(string: "https://fixture.example/a.mp4")!,
                                                        requiresGateway: true)
        #expect(AppleStremioCandidateRanking.playbackClass(AppleStremioCandidateRanking.traits(of: gateway)) == .remux)
    }

    /// Writes the ranking table for the sample to
    /// `OPENSTREAM_N38_TABLE` — the N38 proof, generated by the real code.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_N38_TABLE"] != nil))
    func writesTheRankingTable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OPENSTREAM_N38_TABLE"])
        var lines = ["# N38 quality ranking for a sample candidate list (fixture names)", ""]
        let devices: [(String, AppleStreamDeviceCapabilities)] = [
            ("Apple TV 4K on a Dolby Vision TV", Self.dolbyVisionTV), ("Mac with an HDR display", Self.hdrMac),
            ("SDR display", Self.sdrScreen), ("iPhone (Automatic capped at 1080p)", Self.phone)]
        for (label, device) in devices {
            let tiers = AppleStremioCandidateRanking.qualityTiers(Self.sample, device: device)
            lines.append("## \(label) — picker: Automatic, \(tiers.map(\.title).joined(separator: ", "))")
            for choice in [AppleStreamQualityChoice.automatic] + tiers.map(AppleStreamQualityChoice.tier) {
                let name = if case .tier(let tier) = choice { tier.title } else { "Automatic" }
                let order = AppleStremioCandidateRanking.playbackOrder(Self.sample, choice: choice, device: device)
                lines.append("- \(name): " + order.prefix(4).enumerated().map { index, candidate in
                    let traits = AppleStremioCandidateRanking.traits(of: candidate)
                    return "\(index + 1). \(candidate.filename ?? "") [\(AppleStremioCandidateRanking.playbackClass(traits))]"
                }.joined(separator: "  "))
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
