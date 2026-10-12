import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Stream format badges")
struct AppleStreamFormatBadgeTests {
    @Test("A remux release name gives resolution, Dolby Vision, Atmos, 7.1 and Remux, best first")
    func parsesFullReleaseName() {
        let badges = AppleStreamFormatBadge.parse("Dune.Part.Two.2024.2160p.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-GRP.mkv")
        #expect(badges == [.uhd, .dolbyVision, .atmos, .surround71, .remux])
    }

    @Test("HDR10+ beats HDR10, and plain HDR reads as HDR10")
    func dynamicRange() {
        #expect(AppleStreamFormatBadge.parse("Film 1080p HDR10+ x265").contains(.hdr10Plus))
        #expect(!AppleStreamFormatBadge.parse("Film 1080p HDR10+ x265").contains(.hdr10))
        #expect(AppleStreamFormatBadge.parse("Film 4K HDR WEB-DL") == [.uhd, .hdr10])
        #expect(AppleStreamFormatBadge.parse("Film 1080p WEB-DL DDP5.1") == [.fullHD, .surround51])
    }

    @Test("Channel layouts need their own digits: 5.1 in DDP5.1, not in 15.1 or 5.10")
    func channelBoundaries() {
        #expect(AppleStreamFormatBadge.parse("DDP5.1").contains(.surround51))
        #expect(AppleStreamFormatBadge.parse("AAC 5 1").contains(.surround51))
        #expect(!AppleStreamFormatBadge.parse("version 15.1").contains(.surround51))
        #expect(!AppleStreamFormatBadge.parse("v5.10").contains(.surround51))
        #expect(!AppleStreamFormatBadge.parse("DVD rip").contains(.dolbyVision))
    }

    @Test("A stream candidate reads its description, title and behaviorHints filename")
    func candidateText() {
        let candidate = AppleStremioHTTPPlaybackCandidate(
            title: "Torrentio 4k", sourceURL: URL(string: "https://fixture.example/play/abc")!,
            filename: "Movie.2023.2160p.UHD.BluRay.Remux.HDR10.DTS-HD.MA.5.1.mkv",
            qualityDescription: "💾 60 GB ⚙️ Dolby Atmos")
        #expect(AppleStreamFormatBadge.badges(for: candidate) == [.uhd, .hdr10, .atmos, .surround51, .remux])
    }

    @Test("The probe maps size, range and audio; name adds Remux")
    func probeMapping() {
        let probe = AppleStreamFormatBadge.ProbedFormat(width: 3840, height: 1600, dynamicRange: .dolbyVision,
                                                        audioChannels: 8, isAtmos: true)
        let probed = AppleStreamFormatBadge.badges(for: probe)
        #expect(probed == [.uhd, .dolbyVision, .atmos, .surround71])
        let merged = AppleStreamFormatBadge.merged(probed: probed, named: AppleStreamFormatBadge.parse("Film.1080p.REMUX.mkv"))
        #expect(merged == [.uhd, .dolbyVision, .atmos, .surround71, .remux])
        let dvd = AppleStreamFormatBadge.ProbedFormat(width: 720, height: 480, dynamicRange: .sdr, audioChannels: 6, isAtmos: false)
        #expect(AppleStreamFormatBadge.badges(for: dvd) == [.surround51])
    }

    @Test("A probe without audio keeps the name's sound; without a probe the name stands")
    func mergeFallbacks() {
        let silent = AppleStreamFormatBadge.badges(for: .init(width: 1920, height: 1080, dynamicRange: .sdr,
                                                              audioChannels: 0, isAtmos: false))
        #expect(AppleStreamFormatBadge.merged(probed: silent, named: [.atmos, .surround71]) == [.fullHD, .atmos, .surround71])
        #expect(AppleStreamFormatBadge.merged(probed: nil, named: [.remux, .uhd]) == [.uhd, .remux])
    }

    @Test("Quality rows show no badges; the meta line leaves out what the catalog shows")
    func rowAndMetaFiltering() {
        let badges: [AppleStreamFormatBadge] = [.uhd, .hdr10, .atmos]
        #expect(AppleStreamFormatBadge.rowBadges(badges).isEmpty)
        #expect(AppleStreamFormatBadge.titles(badges, excludingCatalogBadges: ["4K", "HDR"]) == ["Atmos"])
        #expect(AppleStreamFormatBadge.titles([.fullHD], excludingCatalogBadges: ["HD"]) == [])
        #expect(AppleStreamFormatBadge.normalized([.fullHD, .uhd, .hdr10, .dolbyVision, .surround51, .surround71])
            == [.uhd, .dolbyVision, .surround71])
    }

    @Test("Badge words are plain text, never a wordmark")
    func titles() {
        #expect(AppleStreamFormatBadge.allCases.map(\.title)
            == ["4K", "1080p", "Dolby Vision", "HDR10+", "HDR10", "Atmos", "7.1", "5.1", "Remux"])
    }
}
