import Foundation
import Observation

struct AppleCatalogSearchMatch: Equatable, Sendable {
    let item: AppleCatalogItem
    let source: AppleSource
    var localGroupID: String? = nil

    static func indexed(_ record: AppleMediaRecord, sources: [AppleSource]) -> Self? {
        guard let route = record.availability.first(where: { route in
            sources.contains { $0.id == route.instanceID && $0.isEnabled
                && ($0.kind != .mediaServer || route.serverItemID?.isEmpty == false) }
        }), let source = sources.first(where: { $0.id == route.instanceID }) else { return nil }
        let type = record.kind == .series ? "series" : record.kind == .channel ? "tv" : "movie"
        let mediaID: String
        if source.kind == .mediaServer, let itemID = route.serverItemID {
            mediaID = AppleMediaServerItemReference(sourceID: source.id, itemID: itemID).mediaID
        } else {
            mediaID = record.canonicalID ?? record.id
        }
        let title = record.kind == .channel ? AppleChannelPresentation.displayName(record.title) : record.title
        return .init(item: .init(mediaID: mediaID, type: type, name: title,
            posterURL: record.artworkURL, backgroundURL: record.backdropURL, summary: record.summary,
            releaseInfo: record.year.map(String.init), imdbID: record.canonicalID), source: source)
    }

    /// A title known only from TMDB (a Top 10 row, a shared link) opens its
    /// page with no source of its own.
    static func metadataOnly(_ item: AppleCatalogItem) -> Self {
        Self(item: item, source: metadataSource)
    }

    private static let metadataSource = AppleSource(id: AppleMediaAvailability.metadataOnlyInstanceID, kind: .library,
                                                    name: "oStream", url: URL(string: "openstream://metadata")!)
}

struct AppleCatalogSearchMetrics: Equatable, Sendable {
    let debounceDuration: Duration
    let fetchDuration: Duration
}

struct AppleCatalogSearchRow: Identifiable, Sendable {
    let record: AppleMediaRecord
    let match: AppleCatalogSearchMatch
    let displayTitle: String
    var id: String { record.id }

    init(record: AppleMediaRecord, match: AppleCatalogSearchMatch) {
        self.record = record
        self.match = match
        displayTitle = record.kind == .channel ? AppleChannelPresentation.displayName(record.title) : record.title
    }
}

@MainActor
@Observable
final class AppleCatalogSearchStore {
    typealias LocalSearch = @MainActor (String) async -> [AppleMediaRecord]
    typealias ResolveMatch = @MainActor (AppleMediaRecord) -> AppleCatalogSearchMatch?

    struct Identity: Equatable {
        let query: String
        let contentRevision: String?
    }

    private(set) var results: [AppleMediaRecord] = []
    private(set) var rows: [AppleCatalogSearchRow] = []
    private(set) var contentRevision = ""
    private(set) var isSearching = false
    private(set) var metrics: AppleCatalogSearchMetrics?

    private let debounce: Duration
    private let revisionDebounce: Duration
    private let maximumResults: Int
    private var generation: UInt64 = 0

    init(debounce: Duration = .milliseconds(100), maximumResults: Int = 100, revisionDebounce: Duration = .milliseconds(350)) {
        self.debounce = max(debounce, .zero)
        self.revisionDebounce = max(revisionDebounce, .zero)
        self.maximumResults = min(max(maximumResults, 1), 100)
    }

    func taskIdentity(query: String) -> Identity {
        let isTextQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AppleSharedLinkResolver.link(in: query) == nil
        return Identity(query: query, contentRevision: isTextQuery ? contentRevision : nil)
    }

    func coalesceRevision(_ revision: String) async {
        guard contentRevision != revision else { return }
        do { try await Task.sleep(for: revisionDebounce) }
        catch { return }
        guard !Task.isCancelled else { return }
        contentRevision = revision
    }

    func search(query: String, resolveMatch: ResolveMatch? = nil, localSearch: @escaping LocalSearch) async {
        generation &+= 1
        let currentGeneration = generation
        let value = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else {
            results = []
            rows = []
            metrics = nil
            isSearching = false
            return
        }

        isSearching = true
        defer {
            if generation == currentGeneration { isSearching = false }
        }
        // The rows on screen re-rank against what is typed now, before the
        // search answers: "saturday night live" sat under the
        // "saturday night li" list (Life, Lights, then Live) until the slow
        // search came back (Apple TV regression 2026-10-01).
        let matchesByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.match) })
        results = Self.mergedResults(results, matching: value, limit: maximumResults)
        rows = results.compactMap { record in
            matchesByID[record.id].map { AppleCatalogSearchRow(record: record, match: $0) }
        }

        let clock = ContinuousClock()
        let debounceStart = clock.now
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        let debounceDuration = debounceStart.duration(to: clock.now)
        guard generation == currentGeneration, !Task.isCancelled else { return }

        let fetchStart = clock.now
        let localRecords = await localSearch(value)
        guard generation == currentGeneration, !Task.isCancelled else { return }
        let prepared = await Self.prepareResults(localRecords, matching: value, limit: maximumResults)
        let fetchDuration = fetchStart.duration(to: clock.now)
        guard generation == currentGeneration, !Task.isCancelled else { return }

        results = prepared
        rows = prepared.compactMap { record in
            guard let match = resolveMatch?(record) else { return nil }
            return AppleCatalogSearchRow(record: record, match: match)
        }
        metrics = AppleCatalogSearchMetrics(
            debounceDuration: debounceDuration,
            fetchDuration: fetchDuration
        )
    }

    @concurrent nonisolated private static func prepareResults(
        _ records: [AppleMediaRecord], matching query: String, limit: Int
    ) async -> [AppleMediaRecord] {
        guard !Task.isCancelled else { return [] }
        return mergedResults(records, matching: query, limit: limit)
    }

    /// Whether a row that resolves to no title page should still be listed:
    /// library files, server titles and channels are; a record whose every
    /// availability is a resolvable entry has nothing else to offer.
    nonisolated static func listsUnmatched(_ record: AppleMediaRecord) -> Bool {
        !record.availability.allSatisfy { $0.capability == .resolvable }
    }

    /// Search results are titles, not files.
    ///
    /// The media index holds one record per library **file**, so a show with
    /// eight episodes on disk produced eight near-identical rows. The owner
    /// searched "Jury Duty" and got a page of them: "I don't want episode
    /// results ideally show and movies only" (2026-09-15).
    ///
    /// Two changes: episodes are dropped outright, and what is left collapses
    /// on title and year rather than on record id. That also merges a local
    /// copy with a server's entry for the same title, so one row carries the
    /// richer artwork and summary *and* every availability, instead of
    /// appearing twice.
    ///
    /// Channels are kept — the field offers "movies, shows, and channels".
    /// Internal rather than private so the collapsing rules can be tested
    /// directly; the duplicate-row bug lived here and was invisible from the
    /// public surface. It and its helpers read nothing but their arguments,
    /// so they are `nonisolated`: callers need not wait for the main actor.
    nonisolated static func mergedResults(
        _ values: [AppleMediaRecord],
        matching query: String,
        limit: Int
    ) -> [AppleMediaRecord] {
        let tokens = normalized(query).split(separator: " ")
        var recordsByID: [String: AppleMediaRecord] = [:]
        // Two records naming the same canonical id are the same title, whatever
        // their years say. Searching "jury duty" returned the 2007 series twice
        // — once carrying its year, once with none — because the collapse key
        // is title|year and "2007" and "" are different keys. The first record to claim a canonical id owns the
        // key; later ones with that id merge into it.
        var keysByCanonicalID: [String: String] = [:]
        for value in values where value.kind != .episode && matches(value, tokens: tokens) {
            var key = collapseKey(value)
            if let canonical = value.canonicalID, !canonical.isEmpty {
                if let claimed = keysByCanonicalID[canonical] {
                    key = claimed
                } else {
                    keysByCanonicalID[canonical] = key
                }
            }
            if let existing = recordsByID[key] {
                recordsByID[key] = merge(existing, value)
            } else {
                recordsByID[key] = value
            }
        }
        let normalizedQuery = tokens.joined(separator: " ")
        // Ranking keys computed once per record, not per comparison.
        let keyed = recordsByID.values.map { record -> (AppleMediaRecord, Int, String) in
            (record, relevance(record, query: normalizedQuery), normalized(record.title))
        }
        return keyed.sorted { lhsEntry, rhsEntry in
            let (lhs, lhsRelevance, lhsTitle) = lhsEntry
            let (rhs, rhsRelevance, rhsTitle) = rhsEntry
            // Titles that are or begin with the query, ahead of titles that
            // only contain it somewhere.
            let lhsTier = tier(lhsRelevance), rhsTier = tier(rhsRelevance)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            // Namesakes ("General Hospital" ×4): sources, then the year.
            if lhsTitle == rhsTitle, let exactOrder = exactMatchOrder(lhs, rhs) { return exactOrder }
            // Nothing to tell them apart: the exact title, then A–Z.
            if lhsRelevance != rhsRelevance { return lhsRelevance < rhsRelevance }
            if lhsRelevance == 0, let exactOrder = exactMatchOrder(lhs, rhs) { return exactOrder }
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
            return lhs.id < rhs.id
        }.prefix(limit).map(\.0)
    }

    /// How directly a matched title answers the query — 0 best.
    ///
    /// Alphabetical order alone is right only when nothing that matched sorts
    /// ahead of the thing that was asked for. Typing "Dune" on the phone
    /// returned *Be Dune Teen*, *Children of Dune* and *Destination Dune* above
    /// *Dune* itself, because every one of them contains the word and B, C and
    /// D-e sort before D-u (owner review, 2026-09-17). The corpus test missed
    /// it: none of its 206 titles is a decoy that sorts ahead of an exact match.
    ///
    /// Ties still break alphabetically, so *Dune* stays ahead of *Dune: Part
    /// Two* and the ordering that was already right does not move.
    /// The tier a result sorts in: the title is or begins with the query
    /// (0), or only contains it (1). Within a tier the exact title comes
    /// first.
    nonisolated static func tier(_ relevance: Int) -> Int { relevance < 2 ? 0 : 1 }

    nonisolated static func relevance(_ record: AppleMediaRecord, query: String) -> Int {
        guard !query.isEmpty else { return 2 }
        let title = normalized(record.title)
        if title == query { return 0 }
        if record.aliases.contains(where: { normalized($0) == query }) { return 0 }
        if title.hasPrefix(query) { return 1 }
        return 2
    }

    /// Among titles that all match the query exactly, which comes first.
    ///
    /// "stranger things" put the 2013 film above the 2016 series, because
    /// exact matches then fell back to alphabetical order and the id (full
    /// test 2026-10-01). The title more sources carry is the one people mean
    /// (the merged rows are the popularity signal there is), then the newer
    /// one, then a show or film ahead of a bare library file. Nil when none
    /// of those tells them apart.
    nonisolated static func exactMatchOrder(_ lhs: AppleMediaRecord, _ rhs: AppleMediaRecord) -> Bool? {
        let lhsSources = Set(lhs.availability.map(\.instanceID)).count
        let rhsSources = Set(rhs.availability.map(\.instanceID)).count
        if lhsSources != rhsSources { return lhsSources > rhsSources }
        if let lhsYear = lhs.year, let rhsYear = rhs.year, lhsYear != rhsYear { return lhsYear > rhsYear }
        let lhsTitled = lhs.kind == .series || lhs.kind == .movie
        let rhsTitled = rhs.kind == .series || rhs.kind == .movie
        if lhsTitled != rhsTitled { return lhsTitled }
        return nil
    }

    /// One row per title: the normalised name and the year.
    ///
    /// The kind is deliberately *not* part of the key. A library file's kind is
    /// `.video`, which is the absence of a classification rather than a real
    /// one, so including it would keep a local copy and a server's entry for
    /// it apart — the merge that makes a result useful.
    nonisolated private static func collapseKey(_ record: AppleMediaRecord) -> String {
        "\(normalized(record.title))|\(record.year.map(String.init) ?? "")"
    }

    /// Whether a record answers the query.
    ///
    /// This used to be raw substring containment over the title, the aliases
    /// **and the canonical id**, which produced the "odd results" the owner
    /// reported. Measured against a 206-title corpus: "Her" returned
    /// *Sherlock*, "Ran" returned *Stranger Things*, "It" returned 18 titles,
    /// and a bare digit string matched whichever title happened to carry those
    /// digits in its IMDb number.
    ///
    /// A token now has to begin a word — "her" does not begin "sherlock" — or
    /// begin the title with its spaces removed, which is what lets "mash" find
    /// *M\*A\*S\*H* and "walle" find *WALL·E*. The id is matched only in full.
    nonisolated private static func matches(_ record: AppleMediaRecord, tokens: [Substring]) -> Bool {
        guard !tokens.isEmpty else { return false }
        if let canonical = record.canonicalID?.lowercased(),
           tokens.count == 1, tokens[0] == canonical {
            return true
        }
        let words = normalized(([record.title] + record.aliases).joined(separator: " "))
            .split(separator: " ")
        let compact = words.joined()
        return tokens.allSatisfy { token in
            // A four-digit token may be the year rather than part of the title:
            // people type "dune 2021" and "it 2017" to tell two versions apart,
            // and that used to return **nothing**, because the year appears
            // nowhere in the title. Still falls through to the title, so "1917"
            // and "2001" keep finding the films named after them.
            if token.count == 4, let year = Int(token), record.year == year { return true }
            return words.contains { $0.hasPrefix(token) } || compact.hasPrefix(token)
        }
    }

    nonisolated private static func merge(_ lhs: AppleMediaRecord, _ rhs: AppleMediaRecord) -> AppleMediaRecord {
        var result = metadataScore(rhs) > metadataScore(lhs) ? rhs : lhs
        result.availability = Dictionary(grouping: lhs.availability + rhs.availability, by: \.instanceID)
            .compactMap { _, values in values.max { $0.lastVerified < $1.lastVerified } }
            .sorted { $0.instanceID.uuidString < $1.instanceID.uuidString }
        result.aliases = Array(Set(lhs.aliases + rhs.aliases)).sorted()
        result.isFavorite = lhs.isFavorite || rhs.isFavorite
        result.progress = lhs.progress ?? rhs.progress
        result.isPrivate = lhs.isPrivate || rhs.isPrivate
        result.lastVerified = max(lhs.lastVerified, rhs.lastVerified)
        return result
    }

    nonisolated private static func metadataScore(_ record: AppleMediaRecord) -> Int {
        (record.summary == nil ? 0 : 4)
            + (record.artworkURL == nil ? 0 : 2)
            + (record.year == nil ? 0 : 1)
            + min(record.aliases.count, 2)
    }

    nonisolated private static func normalized(_ value: String) -> String {
        // "&" becomes "and" before punctuation is stripped, so "Law & Order"
        // and someone typing "law and order" reach the same words.
        value.replacingOccurrences(of: "&", with: " and ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
