import Foundation

/// File-scoped disk cache and a bounded lookup budget shared by all Library shelves.
actor AppleLibraryMetadataResolver {
    static let shared = AppleLibraryMetadataResolver()
    static let maximumConcurrentLookups = 10
    typealias Lookup = @Sendable (AppleLibraryTitle, String, String) async throws -> AppleCatalogItem?
    private struct Entry: Codable {
        let value: AppleCatalogItem?
        let checkedAt: Date
        let addedAt: Date
        /// Which shape of `AppleCatalogItem` this entry was written with.
        /// Absent in everything written before `schema` existed, which reads
        /// back as `0` — see `currentSchema`.
        var schema: Int?
        var reason: MissReason?
        var parserVersion: Int?
        var configuration: String?
        var attempts: Int?
    }

    /// Schema 2 carries genres. Schema 3 (2026-10-22) is TMDB-only: older
    /// entries may hold artwork from the retired catalog fallback, so they
    /// show their title without artwork while the background refresh runs.
    private static let currentSchema = 3

    private static func currentValue(_ entry: Entry?) -> AppleCatalogItem? {
        guard let entry, let value = entry.value else { return nil }
        return entry.schema == currentSchema ? value : value.withoutArtwork
    }

    struct MatchRecord: Codable, Sendable {
        let candidate: AppleCatalogItem
        let explicitIDs: [String: String]
        let provider: String
        let confidence: Double
        let isManual: Bool
        let matchedAt: Date
    }

    private static let minimumReusableConfidence = 0.95
    private static let reusableProviders: Set<String> = ["tmdb", "omdb"]
    private static let minimumTieBreakVotes = 100
    private static let minimumTieBreakVoteRatio = 10
    /// A widely seen film needs a smaller lead: a hit's same-name knockoff
    /// collects mistaken votes (The Odyssey, 2026: 4,459 to 777 on TMDB).
    private static let widelySeenVotes = 1_000
    private static let widelySeenVoteRatio = 4

    private static func isReusableAutomaticMatch(_ record: MatchRecord, parsed: AppleLibraryTitle) -> Bool {
        let provider = String(record.provider.prefix(while: { $0 != ":" }))
        guard !record.isManual, record.confidence >= minimumReusableConfidence, reusableProviders.contains(provider),
              parsed.kind != .other, record.candidate.type == (parsed.kind == .show ? "series" : "movie"),
              parsed.explicitIDs.allSatisfy({ id in record.explicitIDs[id.key].map { $0 == id.value } ?? true }) else { return false }
        return searchQueries(parsed).contains { query in
            normalized(record.candidate.name) == normalized(query.title)
                && (query.year == nil || releaseYear(record.candidate) == query.year)
        }
    }

    private let matchDirectory: URL
    private let directory: URL
    private struct LookupEvidence: Sendable {
        let candidate: AppleCatalogItem
        let provider: String
    }
    private let lookup: Lookup?
    private let tmdbClient: AppleTMDBClient
    struct Poster: Equatable, Sendable {
        let url: URL
        let mediaID: String
    }
    private var posterObservers: [String: [UUID: AsyncStream<Poster>.Continuation]] = [:]
    private var acceptedPosters: [String: Poster] = [:]
    private var active = 0
    private var lookupWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    enum MissReason: String, Codable, Sendable { case noMatch, providerUnreachable, configMissing }
    private let sharedLookups = AppleSharedMetadataLookup<AppleCatalogItem?>()
    var activeLookupWaiterCount: Int { get async { await sharedLookups.activeWaiterCount } }

    static func retryInterval(reason: MissReason, attempts: Int) -> TimeInterval {
        switch reason {
        case .noMatch: 3600
        case .configMissing: 3600
        case .providerUnreachable: min(900, 30 * pow(2, Double(min(5, max(0, attempts - 1)))))
        }
    }

    /// Seven days plus a stable per-entry spread of up to two days, so a
    /// library scanned in one sitting does not come due on the same day.
    static func revalidationAge(for cacheKey: String) -> TimeInterval {
        let hash = cacheKey.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return 604800 + TimeInterval(hash % 172800)
    }

    static func cacheIsFresh(value: AppleCatalogItem?, reason: MissReason?, checkedAt: Date,
                             attempts: Int, parserVersion: Int?, configuration: String?,
                             currentConfiguration: String, now: Date, revalidateAfter: TimeInterval = 604800) -> Bool {
        if value == nil || reason != nil {
            guard parserVersion == AppleLibraryTitleParser.version, configuration == currentConfiguration,
                  let reason else { return false }
            return now.timeIntervalSince(checkedAt) < retryInterval(reason: reason, attempts: attempts)
        }
        return now.timeIntervalSince(checkedAt) < revalidateAfter
            && (configuration == nil || configuration == currentConfiguration)
    }

    static func configurationDigest(_ tmdb: String, _ omdb: String) -> String {
        // Hash the configuration; never persist the keys themselves.
        ApplePlaybackIdentity.digest(for: [tmdb, omdb].joined(separator: "\n"))
    }

    init(directory: URL? = nil, matchDirectory: URL? = nil,
         tmdbClient: AppleTMDBClient = AppleTMDBClient(), lookup: Lookup? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryTitles-v1")
        self.matchDirectory = matchDirectory ?? directory?.appendingPathComponent("Matches")
            ?? AppleStorageLocation.directory(.applicationSupport)
                .appendingPathComponent("OpenStream").appendingPathComponent("LibraryMatches-v1")
        self.lookup = lookup
        self.tmdbClient = tmdbClient
    }

    func datedItems(_ items: [AppleLibraryItem], sourceID: UUID) throws -> [AppleLibraryItem] {
        let folder = directory.appendingPathComponent(sourceID.uuidString)
        let file = folder.appendingPathComponent("added.json")
        var dates = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        let now = Date()
        // A share's first scan finds the whole collection at once; its change
        // dates order it better than one shared scan time. Later arrivals are
        // dated when a scan first sees them.
        let isFirstScan = dates.isEmpty
        let result = items.map { item in
            let key = ApplePlaybackIdentity.digest(for: item.relativePath)
            let firstSeen = isFirstScan ? min(item.modifiedAt ?? now, now) : now
            let date = dates[key] ?? (item.addedAt == .distantPast ? firstSeen : item.addedAt)
            dates[key] = date
            return AppleLibraryItem(sourceID: item.sourceID, name: item.name, url: item.url,
                relativePath: item.relativePath, sizeBytes: item.sizeBytes, addedAt: date, modifiedAt: item.modifiedAt)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(dates).write(to: file, options: .atomic)
        return result
    }

    /// Known matches, plus the titles whose last lookup found no such title,
    /// from one read of each cache file. An outage or a missing key is not a
    /// no-match, and a manual correction is always a match.
    func cachedLookups(for groups: [AppleLibrarySeries]) -> (metadata: [String: AppleCatalogItem], noMatch: Set<String>) {
        var metadata: [String: AppleCatalogItem] = [:]
        var noMatch = Set<String>()
        for group in groups {
            guard let item = group.items.first else { continue }
            if let record = matchRecord(for: item) {
                if record.isManual {
                    metadata[group.id] = record.candidate
                    continue
                }
                if Self.isReusableAutomaticMatch(record, parsed: AppleLibraryTitleParser.parse(item)) {
                    metadata[group.id] = record.candidate
                }
            }
            guard let data = try? Data(contentsOf: cacheURL(item)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            // Keep a known title visible while an older entry refreshes.
            if entry.value != nil {
                if (1...Self.currentSchema).contains(entry.schema ?? 0),
                   entry.schema == Self.currentSchema || metadata[group.id] == nil { metadata[group.id] = Self.currentValue(entry) }
            } else if entry.reason == .noMatch, metadata[group.id] == nil {
                noMatch.insert(group.id)
            }
        }
        return (metadata, noMatch)
    }

    func needsRevalidation(_ item: AppleLibraryItem, tmdbKey: String, omdbKey: String) -> Bool {
        if let record = matchRecord(for: item), record.isManual { return false }
        let file = cacheURL(item)
        guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              (entry.schema ?? 0) == Self.currentSchema else { return true }
        return !Self.cacheIsFresh(value: entry.value, reason: entry.reason, checkedAt: entry.checkedAt,
            attempts: entry.attempts ?? 1, parserVersion: entry.parserVersion, configuration: entry.configuration,
            currentConfiguration: Self.configurationDigest(tmdbKey, omdbKey), now: .now,
            revalidateAfter: Self.revalidationAge(for: Self.cacheKey(item)))
    }

    static func cacheKey(_ item: AppleLibraryItem) -> String {
        ApplePlaybackIdentity.digest(for: "\(item.relativePath)|\(item.sizeBytes)")
    }

    private func cacheURL(_ item: AppleLibraryItem) -> URL {
        directory.appendingPathComponent(item.sourceID.uuidString).appendingPathComponent(Self.cacheKey(item) + ".json")
    }

    func resolve(_ item: AppleLibraryItem, tmdbKey: String, omdbKey: String, refresh: Bool = false,
                 posters: AsyncStream<Poster>.Continuation? = nil) async throws -> AppleCatalogItem? {
        defer { posters?.finish() }
        try Task.checkCancellation()
        guard !AppleLibraryTitleParser.isSupplemental(item) else { return nil }
        let record = matchRecord(for: item)
        if let record, record.isManual { return record.candidate }
        let key = item.sourceID.uuidString + Self.cacheKey(item) + Self.configurationDigest(tmdbKey, omdbKey)
        let observerID = UUID()
        if let posters {
            posterObservers[key, default: [:]][observerID] = posters
            if let poster = acceptedPosters[key] { posters.yield(poster) }
        }
        defer {
            posterObservers[key]?[observerID] = nil
            if posterObservers[key]?.isEmpty == true {
                posterObservers[key] = nil
            }
        }
        let value = try await sharedLookups.value(for: key) { [self] in
            try await performResolve(item, record: record, tmdbKey: tmdbKey, omdbKey: omdbKey, refresh: refresh,
                posterKey: key)
        }
        try Task.checkCancellation()
        if let record = matchRecord(for: item), record.isManual { return record.candidate }
        return value
    }

    private func publishPoster(_ poster: Poster, for key: String) {
        acceptedPosters[key] = poster
        guard let observers = posterObservers[key] else { return }
        for observer in observers.values { observer.yield(poster) }
    }

    private func performResolve(_ item: AppleLibraryItem, record: MatchRecord?, tmdbKey: String, omdbKey: String,
                                refresh: Bool, posterKey: String) async throws -> AppleCatalogItem? {
        defer { acceptedPosters[posterKey] = nil }
        try Task.checkCancellation()
        var parsed = AppleLibraryTitleParser.parse(item)
        let file = cacheURL(item)
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        let knownMatch = record.flatMap { Self.isReusableAutomaticMatch($0, parsed: parsed) ? $0 : nil }
        let configuration = Self.configurationDigest(tmdbKey, omdbKey)
        if !refresh, let cached, (cached.schema ?? 0) == Self.currentSchema, cached.value != nil || knownMatch == nil,
           Self.cacheIsFresh(value: cached.value, reason: cached.reason, checkedAt: cached.checkedAt,
                             attempts: cached.attempts ?? 1, parserVersion: cached.parserVersion,
                             configuration: cached.configuration, currentConfiguration: configuration, now: .now,
                             revalidateAfter: Self.revalidationAge(for: Self.cacheKey(item))) {
            if let value = cached.value, record == nil {
                saveAutomaticMatch(for: item, candidate: value, provider: "legacyCache", explicitIDs: parsed.explicitIDs)
            }
            return cached.value
        }
        try await acquireLookup()
        defer { releaseLookup() }
        try Task.checkCancellation()
        if !refresh, let knownMatch {
            parsed.explicitIDs.merge(knownMatch.explicitIDs) { filename, _ in filename }
        }
        guard parsed.role == .feature, parsed.kind != .other else { return nil }
        var evidence: LookupEvidence?
        var reason: MissReason = .noMatch
        do {
            for query in Self.searchQueries(parsed) {
                try Task.checkCancellation()
                if let lookup {
                    evidence = try await lookup(query, tmdbKey, omdbKey).map { LookupEvidence(candidate: $0, provider: "injectedLookup") }
                } else {
                    evidence = try await Self.liveLookupEvidence(query, tmdbKey, omdbKey,
                        tmdbClient: tmdbClient, onPoster: { [self] poster in await publishPoster(poster, for: posterKey) })
                }
                if evidence != nil { break }
            }
        } catch {
            try Task.checkCancellation()
            reason = Self.missReason(error)
        }
        // A transient provider/configuration failure retains known artwork and identity,
        // but its retry reason still gets the short negative-cache backoff.
        // A background revalidation that finds nothing keeps the match it had
        // as a positive for another cycle; only Fix Match or a refresh drops it.
        let keepsPositive = evidence == nil && !refresh && reason == .noMatch
            && (knownMatch != nil || (cached?.value != nil && cached?.reason == nil
                && (1...Self.currentSchema).contains(cached?.schema ?? 0)))
        let value = evidence?.candidate
            ?? ((reason == .providerUnreachable || reason == .configMissing || keepsPositive)
                ? Self.currentValue(cached) ?? knownMatch?.candidate : nil)
        try Task.checkCancellation()
        if let record = matchRecord(for: item), record.isManual { return record.candidate }
        if let evidence {
            saveAutomaticMatch(for: item, candidate: evidence.candidate, provider: evidence.provider, explicitIDs: parsed.explicitIDs)
        }
        let attempts = cached?.configuration == configuration && cached?.reason == reason ? (cached?.attempts ?? 0) + 1 : 1
        let entry = Entry(value: value, checkedAt: Date(), addedAt: cached?.addedAt ?? Date(), schema: Self.currentSchema,
                          reason: evidence == nil && !keepsPositive ? reason : nil, parserVersion: AppleLibraryTitleParser.version,
                          configuration: configuration, attempts: attempts)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        return value
    }

    private func acquireLookup() async throws {
        try Task.checkCancellation()
        if active < Self.maximumConcurrentLookups {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lookupWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelLookup(id) }
        }
    }

    private func releaseLookup() {
        if lookupWaiters.isEmpty { active -= 1 }
        else { lookupWaiters.removeFirst().continuation.resume() }
    }

    private func cancelLookup(_ id: UUID) {
        guard let index = lookupWaiters.firstIndex(where: { $0.id == id }) else { return }
        lookupWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Lookup forms, most specific first: the search-normalised filename (with
    /// the folder's year when the names agree), the nearest title folder, then
    /// the stored identity title. A form adds nothing when an earlier one has
    /// the same name and its year is the same or absent.
    static func searchQueries(_ parsed: AppleLibraryTitle) -> [AppleLibraryTitle] {
        var queries: [AppleLibraryTitle] = []
        for (title, year) in parsed.alternatives.map({ ($0.title, $0.year) }) + [(parsed.title, parsed.year)] {
            guard !queries.contains(where: { normalized($0.title) == normalized(title) && (year == nil || $0.year == year) })
            else { continue }
            var query = AppleLibraryTitle(title: title, year: year, season: parsed.season, episode: parsed.episode, kind: parsed.kind)
            query.explicitIDs = parsed.explicitIDs
            queries.append(query)
        }
        for query in queries {
            let alternate = query.title.contains("&")
                ? query.title.replacingOccurrences(of: "&", with: "and")
                : query.title.replacingOccurrences(of: " and ", with: " & ", options: .caseInsensitive)
            guard alternate != query.title else { continue }
            var variant = AppleLibraryTitle(title: alternate, year: query.year, season: query.season,
                episode: query.episode, kind: query.kind)
            variant.explicitIDs = query.explicitIDs
            queries.append(variant)
        }
        return queries
    }

    /// Long franchise-prefixed filenames may omit the franchise in the catalog.
    /// The full name leads; a four-word suffix still needs the exact release year.
    static func unprefixedTitle(_ parsed: AppleLibraryTitle) -> String? {
        let words = parsed.title.split(whereSeparator: \.isWhitespace)
        guard parsed.kind == .movie, parsed.year != nil, parsed.explicitIDs.isEmpty, words.count >= 5 else { return nil }
        return words.dropFirst().joined(separator: " ")
    }

    static func missReason(_ error: Error) -> MissReason {
        if let error = error as? AppleTMDBError {
            switch error {
            case .invalidCredential, .requestFailed(401), .requestFailed(403): return .configMissing
            case .titleNotFound, .requestFailed(404): return .noMatch
            default: return .providerUnreachable
            }
        }
        return .providerUnreachable
    }

    private func matchURL(_ item: AppleLibraryItem) -> URL {
        let titleID = AppleLibrarySeries.groups([item]).first?.id ?? item.id
        return matchDirectory.appendingPathComponent(ApplePlaybackIdentity.digest(for: titleID) + ".json")
    }

    func matchRecord(for item: AppleLibraryItem) -> MatchRecord? {
        if let data = try? Data(contentsOf: matchURL(item)), let record = try? JSONDecoder().decode(MatchRecord.self, from: data) { return record }
        let parsed = AppleLibraryTitleParser.parse(item)
        let kind: AppleMediaKind = parsed.kind == .show ? .series : .movie
        guard let logicalID = AppleLogicalItemKey.title(kind: kind, imdb: parsed.explicitIDs["imdb"], tmdb: parsed.explicitIDs["tmdb"]) else { return nil }
        return matchRecord(logicalID: logicalID)
    }

    private func logicalMatchURL(_ logicalID: String) -> URL {
        matchDirectory.appendingPathComponent("logical-" + ApplePlaybackIdentity.digest(for: logicalID) + ".json")
    }

    func matchRecord(logicalID: String) -> MatchRecord? {
        guard let data = try? Data(contentsOf: logicalMatchURL(logicalID)), let record = try? JSONDecoder().decode(MatchRecord.self, from: data),
              record.isManual || record.confidence >= 0.95 else { return nil }
        return record
    }

    func strongMatchIDs(for item: AppleLibraryItem) -> (kind: AppleMediaKind, imdb: String?, tmdb: String?)? {
        guard let record = matchRecord(for: item), record.isManual || record.confidence >= 0.95,
              let kind = AppleMediaKind(rawValue: record.candidate.type) else { return nil }
        return (kind, record.explicitIDs["imdb"], record.explicitIDs["tmdb"])
    }

    func correctMatch(for item: AppleLibraryItem, candidate: AppleCatalogItem, provider: String,
                      explicitIDs: [String: String] = [:]) throws {
        try saveMatch(for: item, candidate: candidate, provider: provider, explicitIDs: explicitIDs, isManual: true)
    }

    func isManualMatch(_ item: AppleLibraryItem) -> Bool {
        matchRecord(for: item)?.isManual == true
    }

    /// Removes the manual correction, so the automatic answer is used again.
    func removeManualMatch(for item: AppleLibraryItem) throws {
        guard let record = matchRecord(for: item), record.isManual else { return }
        let fileManager = FileManager.default
        let url = matchURL(item)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        if let kind = AppleMediaKind(rawValue: record.candidate.type),
           let logicalID = AppleLogicalItemKey.title(kind: kind, imdb: record.explicitIDs["imdb"], tmdb: record.explicitIDs["tmdb"]),
           matchRecord(logicalID: logicalID)?.isManual == true {
            try fileManager.removeItem(at: logicalMatchURL(logicalID))
        }
    }

    func saveAutomaticMatch(for item: AppleLibraryItem, candidate: AppleCatalogItem,
                            provider: String, explicitIDs: [String: String]) {
        guard matchRecord(for: item)?.isManual != true else { return }
        do {
            try saveMatch(for: item, candidate: candidate, provider: provider, explicitIDs: explicitIDs, isManual: false)
        } catch {
            // Automatic match persistence must not hide an otherwise usable metadata result.
            // Error descriptions can carry paths; retain only the domain/code.
            let failure = error as NSError
            AppleInteractionTrace.record(.failure, "Library match write failed: \(failure.domain) code=\(failure.code)")
        }
    }

    private func saveMatch(for item: AppleLibraryItem, candidate: AppleCatalogItem, provider: String,
                           explicitIDs: [String: String], isManual: Bool) throws {
        // Automatic aliases come from the resolved record, not unverified filename tags.
        var ids = isManual ? explicitIDs : [:]
        if candidate.mediaID.hasPrefix("tt") { ids["imdb"] = candidate.mediaID }
        if candidate.mediaID.hasPrefix("tmdb:") { ids["tmdb"] = candidate.mediaID.split(separator: ":").last.map(String.init) }
        if let imdb = candidate.imdbID { ids["imdb"] = imdb }
        let parsed = AppleLibraryTitleParser.parse(item)
        let exactYear = parsed.year != nil && parsed.year == Self.releaseYear(candidate)
        let record = MatchRecord(candidate: candidate, explicitIDs: ids, provider: provider,
            confidence: isManual || provider.contains("explicitID") ? 1 : (exactYear ? 0.95 : 0.6), isManual: isManual, matchedAt: .now)
        try FileManager.default.createDirectory(at: matchDirectory, withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(record)
        try encoded.write(to: matchURL(item), options: .atomic)
        if record.isManual || record.confidence >= 0.95,
           let kind = AppleMediaKind(rawValue: candidate.type),
           let logicalID = AppleLogicalItemKey.title(kind: kind, imdb: ids["imdb"], tmdb: ids["tmdb"]),
           isManual || matchRecord(logicalID: logicalID)?.isManual != true {
            try encoded.write(to: logicalMatchURL(logicalID), options: .atomic)
        }
    }

    /// The year disambiguates between films sharing a name; it does not decide
    /// whether a match is real.
    ///
    /// This used to require the parsed year to equal the candidate's
    /// `releaseInfo`, and threw away a correct match when they disagreed.
    /// Providers routinely publish the *production* year there: the owner's
    /// `1992 (2024)` is `tt4959750`, whose cast and `released: 2024-08-30`
    /// make it plainly the 2024 film, while another provider's `releaseInfo` says
    /// 2022. The card had no artwork because a two-year gap in someone else's
    /// metadata outvoted an exact title match (owner 2026-09-15: "1992 still
    /// does not have album art").
    ///
    /// So: an exact year wins, and when nothing matches exactly the year only
    /// chooses *between* same-named candidates. A single same-named candidate
    /// is accepted; multiple same-named candidates need a clear year margin
    /// or a dominant audience among exact-year film records.
    ///
    /// A series with no year takes the provider's first (most popular)
    /// same-named result; the name alone does not disambiguate between
    /// several shows that share it, and Fix Match overrides the pick. Refusing
    /// the tie left a bare `TV/Chernobyl/` unmatched (owner checklist row 20).
    static func bestMatch(_ items: [AppleCatalogItem], parsed: AppleLibraryTitle,
                          aliases: [String: [String]] = [:]) -> AppleCatalogItem? {
        let type = parsed.kind == .show ? "series" : "movie"
        let candidates = items.filter { $0.type == type }
        if let imdb = parsed.explicitIDs["imdb"],
           let explicit = candidates.first(where: { $0.mediaID == imdb || $0.imdbID == imdb }) { return explicit }
        if let tmdb = parsed.explicitIDs["tmdb"],
           let explicit = candidates.first(where: { $0.mediaID == "tmdb:" + tmdb || $0.mediaID == "tmdb:" + (type == "series" ? "tv:" : "movie:") + tmdb }) { return explicit }
        var seen = Set<String>()
        func matching(_ title: String) -> [AppleCatalogItem] {
            candidates.filter {
                ([$0.name] + (aliases[$0.mediaID] ?? [])).contains { normalized($0) == normalized(title) }
                    && seen.insert($0.mediaID).inserted
            }
        }
        var sameName = matching(parsed.title)
        if sameName.isEmpty, let year = parsed.year {
            let title = parsed.title.replacingOccurrences(
                of: #"(?:\s*[\(\[]|\s+)"# + String(year) + #"[\)\]]?\s*$"#,
                with: "", options: .regularExpression)
            if !title.isEmpty { sameName = matching(title) }
        }
        if sameName.isEmpty, let year = parsed.year {
            let titles = ([parsed.title] + (unprefixedTitle(parsed).map { [$0] } ?? [])).map(normalized)
            sameName = candidates.filter { candidate in
                releaseYear(candidate) == year && ([candidate.name] + (aliases[candidate.mediaID] ?? [])).contains {
                    let title = $0.replacingOccurrences(of: #"\s+\([^()]+\)\s*$"#, with: "", options: .regularExpression)
                    return titles.contains(normalized(title))
                } && seen.insert(candidate.mediaID).inserted
            }
        }
        if sameName.isEmpty, parsed.kind == .show, let year = parsed.year,
           parsed.title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter({ !$0.isEmpty }).count >= 3 {
            let prefix = normalized(parsed.title)
            let expanded = candidates.filter {
                normalized($0.name).hasPrefix(prefix) && releaseYear($0) == year
            }
            if expanded.count == 1 { sameName = expanded }
        }
        guard let first = sameName.first else { return nil }
        guard sameName.count > 1 else { return first }
        guard let year = parsed.year else { return type == "series" ? first : nil }
        let ranked = sameName.sorted { distance(releaseYear($0), from: year) < distance(releaseYear($1), from: year) }
        let bestDistance = distance(releaseYear(ranked[0]), from: year)
        let nextDistance = distance(releaseYear(ranked[1]), from: year)
        // TMDB lists shorts and features with identical titles and years.
        // A substantial audience difference is evidence; result order alone is not.
        if type == "movie", bestDistance == 0, nextDistance == 0 {
            let tied = ranked.filter { releaseYear($0) == year }.sorted {
                ($0.voteCount ?? 0) > ($1.voteCount ?? 0)
            }
            let leadingVotes = tied[0].voteCount ?? 0
            let nextVotes = max(1, tied[1].voteCount ?? 0)
            let ratio = leadingVotes / nextVotes
            let decisive = leadingVotes >= widelySeenVotes ? ratio >= widelySeenVoteRatio
                : leadingVotes >= minimumTieBreakVotes && ratio >= minimumTieBreakVoteRatio
            return decisive ? tied[0] : nil
        }
        // Exact years outrank inexact years; inexact candidates need a two-year margin.
        guard bestDistance != .max, nextDistance > bestDistance,
              bestDistance == 0 || nextDistance == .max || nextDistance - bestDistance >= 2 else { return nil }
        return ranked[0]
    }

    private static func releaseYear(_ item: AppleCatalogItem) -> Int? {
        Int((item.releaseInfo ?? "").prefix(4))
    }

    /// Candidates with no year at all sort last rather than counting as zero.
    private static func distance(_ candidate: Int?, from year: Int) -> Int {
        guard let candidate else { return .max }
        return abs(candidate - year)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined()
    }

    static func liveLookup(_ parsed: AppleLibraryTitle, _ tmdbKey: String, _ omdbKey: String) async throws -> AppleCatalogItem? {
        try await liveLookupEvidence(parsed, tmdbKey, omdbKey)?.candidate
    }

    private static func liveLookupEvidence(_ parsed: AppleLibraryTitle, _ tmdbKey: String, _ omdbKey: String,
                                          tmdbClient: AppleTMDBClient = AppleTMDBClient(),
                                          onPoster: (@Sendable (Poster) async -> Void)? = nil) async throws -> LookupEvidence? {
        var failures: [MissReason] = []
        if !parsed.explicitIDs.isEmpty, !tmdbKey.isEmpty {
            do {
                if let candidate = try await directLookup(parsed, client: tmdbClient, configuration: .init(credential: tmdbKey)) {
                    return LookupEvidence(candidate: candidate, provider: "tmdb:explicitID")
                }
            } catch { try Task.checkCancellation(); failures.append(missReason(error)) }
        }
        if parsed.explicitIDs["imdb"] != nil, !omdbKey.isEmpty {
            do {
                if let candidate = try await credentialLookup(parsed, key: omdbKey, tmdb: false) {
                    return LookupEvidence(candidate: candidate, provider: "omdb:explicitID")
                }
            } catch { try Task.checkCancellation(); failures.append(missReason(error)) }
        }
        for (key, isTMDB) in [(tmdbKey, true), (omdbKey, false)] where !key.isEmpty {
            do {
                if let result = try await credentialLookup(parsed, key: key, tmdb: isTMDB,
                    tmdbClient: tmdbClient, onPoster: onPoster) {
                    return LookupEvidence(candidate: result, provider: isTMDB ? "tmdb" : "omdb")
                }
            } catch { try Task.checkCancellation(); failures.append(missReason(error)) }
        }
        if failures.contains(.providerUnreachable) { throw URLError(.cannotConnectToHost) }
        if failures.contains(.configMissing) { throw AppleTMDBError.invalidCredential }
        if tmdbKey.isEmpty && omdbKey.isEmpty { throw AppleTMDBError.invalidCredential }
        return nil
    }

    static func correctionCandidates(query: String, year: Int?, kind: AppleLibraryTitle.Kind,
                                     tmdbKey: String, omdbKey: String) async throws -> [AppleCatalogItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300 else { return [] }
        let title = correctionTitle(query: text, year: year, kind: kind)
        guard !title.explicitIDs.isEmpty else {
            return try await correctionNameCandidates(title, kind: kind, tmdbKey: tmdbKey, omdbKey: omdbKey)
        }
        guard text.allSatisfy(\.isNumber) else {
            return try await liveLookup(title, tmdbKey, omdbKey).map { [$0] } ?? []
        }
        // An all-digit query ("1917", "2012") is a TMDB id and a name, so both
        // run. A year-like query is almost always the name: its results lead.
        let direct: AppleCatalogItem?
        var directError: Error?
        do { direct = try await liveLookup(title, tmdbKey, omdbKey) }
        catch { try Task.checkCancellation(); direct = nil; directError = error }
        let named: [AppleCatalogItem]
        do {
            named = try await correctionNameCandidates(
                AppleLibraryTitle(title: text, year: year, season: nil, episode: nil, kind: kind),
                kind: kind, tmdbKey: tmdbKey, omdbKey: omdbKey)
        } catch {
            try Task.checkCancellation()
            guard let direct else { throw error }
            return [direct]
        }
        if named.isEmpty, direct == nil, let directError { throw directError }
        let looksLikeYear = text.count == 4 && (1880...2100).contains(Int(text) ?? 0)
        let ordered = looksLikeYear ? named + [direct].compactMap { $0 } : [direct].compactMap { $0 } + named
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.mediaID).inserted }
    }

    private static func correctionNameCandidates(_ title: AppleLibraryTitle, kind: AppleLibraryTitle.Kind,
                                                 tmdbKey: String,
                                                 omdbKey: String) async throws -> [AppleCatalogItem] {
        var items: [AppleCatalogItem] = []
        var lastError: Error?
        if !tmdbKey.isEmpty {
            do {
                items += try await AppleTMDBClient().sharedLinkSearch(title: .init(name: title.title, year: title.year,
                    kind: kind == .show ? .show : .movie), configuration: .init(credential: tmdbKey))
            } catch { try Task.checkCancellation(); lastError = error }
        }
        if !omdbKey.isEmpty {
            do {
                if let item = try await credentialLookup(title, key: omdbKey, tmdb: false) { items.append(item) }
            } catch { try Task.checkCancellation(); lastError = error }
        }
        if items.isEmpty, let lastError { throw lastError }
        var seen = Set<String>()
        return items.filter {
            $0.type == (kind == .show ? "series" : "movie") && (title.year == nil || releaseYear($0) == title.year)
                && seen.insert($0.mediaID).inserted
        }
    }

    /// What the Fix Match field means: a bare number (also searched as a name)
    /// or a TMDB page link is a TMDB id, `tt…` (or an IMDb link) an IMDb id, `tvdb-123` / `tvdbid=123` a
    /// TVDB id, anything else a name (with an optional year).
    static func correctionTitle(query text: String, year: Int?, kind: AppleLibraryTitle.Kind) -> AppleLibraryTitle {
        var parsed = AppleLibraryTitleParser.parse(name: text)
        if text.allSatisfy(\.isNumber), let number = Int(text), number > 0 { parsed.explicitIDs["tmdb"] = String(number) }
        if let range = text.range(of: #"(?i)themoviedb\.org/(?:movie|tv)/\d+"#, options: .regularExpression),
           let number = text[range].split(separator: "/").last.flatMap({ Int($0) }), number > 0 {
            parsed.explicitIDs["tmdb"] = String(number)
        }
        var title = AppleLibraryTitle(title: parsed.title, year: year ?? parsed.year, season: nil, episode: nil, kind: kind)
        title.explicitIDs = parsed.explicitIDs
        return title
    }

    static func directLookup(_ parsed: AppleLibraryTitle, client: AppleTMDBClient,
                             configuration: AppleTMDBConfiguration) async throws -> AppleCatalogItem? {
        for provider in ["tmdb", "imdb", "tvdb"] {
            guard let id = parsed.explicitIDs[provider] else { continue }
            do { return try await client.libraryDetails(provider: provider, id: id, kind: parsed.kind, configuration: configuration) }
            catch AppleTMDBError.titleNotFound { continue }
            catch AppleTMDBError.requestFailed(404) { continue }
        }
        return nil
    }

    static func credentialLookup(_ parsed: AppleLibraryTitle, key: String, tmdb: Bool,
                                 tmdbClient: AppleTMDBClient = AppleTMDBClient(),
                                 onPoster: (@Sendable (Poster) async -> Void)? = nil) async throws -> AppleCatalogItem? {
        if tmdb {
            return try await tmdbClient.librarySearch(parsed, configuration: .init(credential: key), onPoster: onPoster)
        }
        let show = parsed.kind == .show
        var components = URLComponents(string: "https://www.omdbapi.com/")!
        let explicit = parsed.explicitIDs["imdb"]
        components.queryItems = [.init(name: explicit == nil ? "t" : "i", value: explicit ?? parsed.title),
                                 .init(name: "type", value: show ? "series" : "movie"), .init(name: "apikey", value: key)]
        if let year = parsed.year, explicit == nil { components.queryItems?.append(.init(name: "y", value: String(year))) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await AppleTMDBClient.liveLoader(request)
        guard data.count < 2_000_000, let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "www.omdbapi.com" else { throw AppleTMDBError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (object?["Error"] as? String)?.lowercased() ?? ""
        // OMDb answers a used-up daily quota (sometimes with HTTP 401) as
        // "Request limit reached!": the provider is unavailable, not the film.
        if object?["Response"] as? String == "False", message.contains("limit") { throw AppleTMDBError.requestFailed(429) }
        guard http.statusCode == 200 else { throw AppleTMDBError.requestFailed(http.statusCode) }
        guard let object else { throw AppleTMDBError.invalidResponse }
        if object["Response"] as? String == "False" {
            if message.contains("api key") { throw AppleTMDBError.invalidCredential }
            return nil
        }
        guard let name = object["Title"] as? String, let id = object["imdbID"] as? String,
              AppleMediaIdentifier.isIMDBIdentifier(id) else { throw AppleTMDBError.invalidResponse }
        let poster = (object["Poster"] as? String).flatMap { $0 == "N/A" ? nil : URL(string: $0) }
        let candidate = AppleCatalogItem(mediaID: id, type: show ? "series" : "movie", name: name,
            posterURL: poster, summary: object["Plot"] as? String, releaseInfo: object["Year"] as? String,
            genres: (object["Genre"] as? String)?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty && $0 != "N/A" },
            voteCount: (object["imdbVotes"] as? String).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) })
        return explicit == id ? candidate : bestMatch([candidate], parsed: parsed)
    }
}
