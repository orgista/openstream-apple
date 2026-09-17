import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15, from a screenshot of the in-player "Other sources"
/// sheet: "this can be worked on our sources maybe remove the [tb+] find a
/// better gui cleans and simpler and less sources like example 1 4k dv
/// selection but the backend will chose the best source of that specific
/// stream i.e. Local or Stream 4k etc". The sheet listed one row per raw
/// candidate — five identical "[TB+] Add-on 1080p" rows from five providers
/// — instead of a short menu of quality choices.
@Suite("Stream source grouping")
struct AppleStreamSourceGroupingTests {
    private typealias G = AppleStreamSourceGrouping

    private func candidate(_ text: String, local: Bool = false) -> G.Candidate {
        G.Candidate(text: text, isLocal: local)
    }

    @Test func duplicateQualitiesCollapseToOneChoice() {
        let candidates = (0 ..< 5).map { candidate("[TB+] Add-on 1080p WEB-DL \($0)") }
        let choices = G.choices(for: candidates)
        #expect(choices.count == 1)
        #expect(choices[0].title == "1080p")
        // The resolver already ranked candidates best-first, so the first
        // member of the bucket — not a re-ranked pick — is the one offered.
        #expect(choices[0].index == 0)
    }

    @Test func localIsRankedDistinctlyFromARemoteStreamOfTheSameQuality() {
        let choices = G.choices(for: [
            candidate("Movie.2024.2160p.mkv", local: true),
            candidate("[TB+] Add-on 4k"),
        ])
        #expect(choices.map(\.title) == ["Local · 4K", "4K"])
        #expect(choices.map(\.index) == [0, 1])
    }

    @Test func dolbyVisionAndHDRAreDistinguishedFromPlain4K() {
        let choices = G.choices(for: [
            candidate("Movie 2160p Dolby Vision REMUX"),
            candidate("Movie 2160p HDR10 REMUX"),
            candidate("Movie 2160p WEB-DL"),
        ])
        #expect(choices.map(\.title) == ["4K Dolby Vision", "4K HDR", "4K"])
    }

    @Test func dvTagAloneIsRecognisedAsDolbyVision() {
        let choices = G.choices(for: [candidate("Movie 1080p DV x265")])
        #expect(choices[0].title == "1080p Dolby Vision")
    }

    @Test func emptyInputProducesNoChoices() {
        #expect(G.choices(for: []).isEmpty)
    }

    @Test func aSingleStreamProducesOneChoiceAtIndexZero() {
        let choices = G.choices(for: [candidate("[RD+] Add-on 720p")])
        #expect(choices.count == 1)
        #expect(choices[0].title == "720p")
        #expect(choices[0].index == 0)
    }

    @Test func unknownQualityFallsBackToAPlainLabelRatherThanNoLabel() {
        #expect(G.choices(for: [candidate("Movie.mkv")])[0].title == "Standard")
        #expect(G.choices(for: [candidate("Movie.mkv", local: true)])[0].title == "Local")
    }

    @Test func providerTagsAreStrippedFromTheDisplayTitle() {
        #expect(G.strippingProviderTag(from: "[TB+] Add-on 4k") == "Add-on 4k")
        #expect(G.strippingProviderTag(from: "[RD] [Cached] Add-on 1080p") == "Add-on 1080p")
        #expect(G.strippingProviderTag(from: "Add-on 1080p") == "Add-on 1080p")
    }
}
