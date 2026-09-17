import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15: "I search for Jury duty and go odd results[,] I don't want
/// episode results ideally show and movies only."
///
/// The media index holds one record per library *file*, so a show with eight
/// episodes on disk produced eight near-identical rows.
@MainActor
@Suite(.serialized)
struct AppleSearchResultShapeTests {
    private func store() -> AppleCatalogSearchStore {
        AppleCatalogSearchStore(
            client: AppleStremioCatalogClient(loader: { _ in throw CancellationError() }),
            debounce: .milliseconds(1),
            deadline: .milliseconds(30),
            maximumResults: 50,
            maximumConcurrentRequests: 1
        )
    }

    private func record(
        _ kind: AppleMediaKind,
        _ title: String,
        year: Int? = nil,
        reference: String = UUID().uuidString,
        summary: String? = nil,
        artwork: URL? = nil
    ) -> AppleMediaRecord {
        AppleMediaRecord(
            canonicalID: reference,
            kind: kind,
            title: title,
            year: year,
            summary: summary,
            artworkURL: artwork,
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: reference)]
        )
    }

    /// Eight files on disk, one show.
    @Test func everyEpisodeFileOfAShowCollapsesToOneRow() async {
        let subject = store()
        let files = (1 ... 8).map { record(.video, "Jury Duty", year: 2023, reference: "s1e\($0)") }
        await subject.search(query: "jury duty", sources: [], baseSections: []) { _ in files }
        #expect(subject.results.count == 1)
        #expect(subject.results.first?.title == "Jury Duty")
    }

    /// An add-on that returns episodes has them dropped outright.
    @Test func episodeRecordsAreNotResults() async {
        let subject = store()
        let mixed = [
            record(.series, "Jury Duty", year: 2023),
            record(.episode, "Jury Duty", year: 2023, reference: "ep1"),
            record(.episode, "Jury Duty", year: 2023, reference: "ep2"),
        ]
        await subject.search(query: "jury duty", sources: [], baseSections: []) { _ in mixed }
        #expect(subject.results.count == 1)
        #expect(subject.results.allSatisfy { $0.kind != .episode })
    }

    /// The local copy and its catalog entry become one row that carries the
    /// catalog's artwork *and* both sources' availability.
    @Test func aLocalCopyMergesWithItsCatalogEntry() async {
        let subject = store()
        let local = record(.video, "Jury Duty", year: 2023, reference: "local")
        let catalog = record(
            .series, "Jury Duty", year: 2023, reference: "tt15557874",
            summary: "A man thinks he is a juror.",
            artwork: URL(string: "https://example.com/art.jpg")
        )
        await subject.search(query: "jury duty", sources: [], baseSections: []) { _ in [local, catalog] }
        #expect(subject.results.count == 1)
        let merged = subject.results.first
        #expect(merged?.summary != nil)
        #expect(merged?.artworkURL != nil)
        #expect(merged?.availability.count == 2)
    }

    /// Different years are different titles and must not merge.
    @Test func twoFilmsOfTheSameNameStaySeparate() async {
        let subject = store()
        let films = [record(.movie, "Dune", year: 1984), record(.movie, "Dune", year: 2021)]
        await subject.search(query: "dune", sources: [], baseSections: []) { _ in films }
        #expect(subject.results.count == 2)
    }

    /// The field offers "movies, shows, and channels" — live channels stay.
    @Test func channelsAreStillResults() async {
        let subject = store()
        await subject.search(query: "news", sources: [], baseSections: []) { _ in
            [self.record(.channel, "News Channel")]
        }
        #expect(subject.results.count == 1)
        #expect(subject.results.first?.kind == .channel)
    }
}
