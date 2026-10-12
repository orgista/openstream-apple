import Foundation
import Testing
@testable import OpenStreamApple

/// The small Apple TV app parity fixes from the N32 sweep: how a year run is
/// printed, what an episode without a still shows, and the card and empty
/// state details that can only be pinned by reading the source.
@Suite("Apple TV visual parity")
struct AppleVisualParityTests {
    @Test("A year run uses an en dash, open-ended or not", arguments: [
        ("1984-", "1984–"),
        ("2013-2018", "2013–2018"),
        ("2011–2019", "2011–2019"),
        (" 2020 - ", "2020–"),
        ("2020—2022", "2020–2022"),
    ])
    func yearRunUsesEnDash(raw: String, expected: String) {
        #expect(AppleReleaseYearText.display(raw) == expected)
    }

    @Test("Anything that is not a year run is left alone", arguments: ["2024", "TBA", "2024-05-01", "", "19-84"])
    func nonRunsAreUntouched(raw: String) {
        #expect(AppleReleaseYearText.display(raw) == raw)
    }

    @Test func titleMetadataLinePrintsRunsWithAnEnDash() {
        #expect(AppleTitleMetadataPresentation.textValues(genres: ["Game Show"], releaseInfo: "1984-", runtimeMinutes: nil)
            == ["Game Show", "1984–"])
        // A full date is still a date.
        #expect(AppleTitleMetadataPresentation.formattedReleaseInfo("2026-09-04") == "Sep 4, 2026")
    }

    @Test func top10SubtitlePrintsRunsWithAnEnDash() {
        let item = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Fixture Show",
                                    releaseInfo: "2020-", genres: ["Drama"])
        #expect(AppleCatalogShelfPolicy.rankedSubtitle(for: item) == "2020– · Drama")
    }

    @Test func episodeWithoutAStillShowsTheSeriesBackdrop() throws {
        let still = try #require(URL(string: "https://fixture.example/still.jpg"))
        let backdrop = try #require(URL(string: "https://fixture.example/backdrop.jpg"))
        #expect(AppleEpisodeStillPolicy.url(still: still, seriesBackdrop: backdrop) == still)
        #expect(AppleEpisodeStillPolicy.url(still: nil, seriesBackdrop: backdrop) == backdrop)
        #expect(AppleEpisodeStillPolicy.url(still: nil, seriesBackdrop: nil) == nil)
        // A still that is named but will not load gives way too.
        #expect(AppleEpisodeStillPolicy.url(still: still, stillFailed: true, seriesBackdrop: backdrop) == backdrop)
        #expect(AppleEpisodeStillPolicy.url(still: still, stillFailed: true, seriesBackdrop: nil) == nil)
    }

    private static func source(_ file: String) throws -> String {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appending(path: "Sources/OpenStreamApple/\(file)"), encoding: .utf8)
    }

    /// The lines from `marker` to the first line at its own indentation that
    /// closes the declaration.
    private static func declaration(_ marker: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains(marker) })
        let indent = lines[start].prefix { $0 == " " }
        let end = lines[(start + 1)...].firstIndex { $0 == "\(indent)}" } ?? lines.count - 1
        return lines[start...end].joined(separator: "\n")
    }

    @Test func cardCaptionIsLeftAlignedWithTheYearUnderTheTitle() throws {
        let captions = try Self.declaration("private func captionLines(reservingTitleLines:",
                                            in: Self.source("AppleDiscoverView.swift"))
        // A link label centres a two-line title unless told otherwise.
        #expect(captions.contains(".multilineTextAlignment(.leading)"))
        // Only the hidden copy holds the second title line open; the visible
        // one puts the year straight under a one-line title.
        #expect(captions.contains(".lineLimit(2, reservesSpace: reservingTitleLines)"))
        #expect(captions.contains("VStack(alignment: .leading, spacing: 2)"))
    }

    @Test func top10CaptionIsLeftAligned() throws {
        let caption = try Self.declaration("private var standardCaption: some View", in: Self.source("AppleDiscoverView.swift"))
        #expect(caption.contains(".multilineTextAlignment(.leading)"))
    }

    @Test func unresolvedTop10CardHasNoSpinnerBesideItsTitle() throws {
        let card = try Self.declaration("private struct AppleTop10SearchCard", in: Self.source("AppleDiscoverView.swift"))
        #expect(!card.contains("ProgressView"))
    }

    @Test func tabEmptyStatesCarryTheTabSymbol() throws {
        #expect(try Self.source("AppleMediaSourceViews.swift").contains("systemImage: OpenStreamTab.library.systemImage"))
        #expect(try Self.source("AppleMediaSourceViews.swift").contains("systemImage: OpenStreamTab.live.systemImage"))
        #expect(try Self.source("AppleDiscoverView.swift").contains("systemImage: OpenStreamTab.home.systemImage"))
    }
}
