import Foundation
import Observation

/// Finds each title's trailer on the user's Plex, Jellyfin and Emby servers
/// and keeps the answer briefly: a server title by its own id, any other by
/// its IMDb or TMDB id (or title and year) among the server's search
/// results. The URLs carry tokens and Plex Pass links expire, so nothing is
/// saved and an answer lives `lifetime`. The trace names the title and the
/// outcome, never a URL.
@MainActor
@Observable
public final class AppleServerTrailerStore {
    public static let shared = AppleServerTrailerStore()
    static let lifetime: TimeInterval = 10 * 60

    /// Moves when the signed-in servers change, so a view asks again.
    public private(set) var revision = 0

    @ObservationIgnored private var sessions: [UUID: AppleMediaServerSession] = [:]
    @ObservationIgnored private var answers: [String: (trailer: AppleServerTrailer?, at: Date)] = [:]
    /// Direct trailer links from Rill's feed (`AppleOStreamFeed`), by media id.
    @ObservationIgnored private var feedTrailers: [String: URL] = [:]
    @ObservationIgnored private var lookups: [String: Task<Lookup, Never>] = [:]
    @ObservationIgnored private let client: AppleMediaServerClient
    @ObservationIgnored private let plexClient: ApplePlexClient
    @ObservationIgnored private let now: @Sendable () -> Date

    init(client: AppleMediaServerClient = AppleMediaServerClient(), plexClient: ApplePlexClient = ApplePlexClient(),
         now: @escaping @Sendable () -> Date = { .now }) {
        self.client = client
        self.plexClient = plexClient
        self.now = now
    }

    /// The media-server library hands over its signed-in sessions on reload.
    func update(sessions: [UUID: AppleMediaServerSession]) {
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        answers.removeAll()
        lookups.values.forEach { $0.cancel() }
        lookups.removeAll()
        revision &+= 1
    }

    func update(feedTrailers: [String: URL]) {
        self.feedTrailers = feedTrailers
    }

    /// The answer already known, without asking a server.
    public func knownTrailer(for mediaID: String) -> AppleServerTrailer?? {
        guard let answer = answers[mediaID], now().timeIntervalSince(answer.at) < Self.lifetime else { return nil }
        return .some(answer.trailer)
    }

    /// Throws only `CancellationError`: the signed-in servers changed while
    /// it was out, and the caller asks again for the new `revision`.
    public func trailer(for item: AppleCatalogItem) async throws -> AppleServerTrailer? {
        try await trailer(for: AppleServerTrailerQuery(item: item))
    }

    public func trailer(for query: AppleServerTrailerQuery) async throws -> AppleServerTrailer? {
        if let known = knownTrailer(for: query.mediaID) { return known }
        guard !sessions.isEmpty else { return nil }
        let lookup = lookups[query.mediaID] ?? Task { await self.resolve(query) }
        lookups[query.mediaID] = lookup
        let lookedUp = await lookup.value
        guard !lookup.isCancelled else { throw CancellationError() }
        if lookups[query.mediaID] == lookup {
            lookups[query.mediaID] = nil
            // A server that did not answer is asked again next time.
            if lookedUp.answered { answers[query.mediaID] = (lookedUp.trailer, now()) }
            let outcome = lookedUp.trailer.map { $0.isFile ? "file" : "conversion" } ?? (lookedUp.answered ? "none" : "no answer")
            appleTrace("server trailer \(outcome) for \(query.title)")
        }
        return lookedUp.trailer
    }

    /// The trailer, and whether every server asked gave an answer.
    private struct Lookup: Sendable {
        var trailer: AppleServerTrailer?
        var answered: Bool
    }

    private func resolve(_ query: AppleServerTrailerQuery) async -> Lookup {
        if let url = feedTrailers[query.mediaID] {
            return Lookup(trailer: AppleServerTrailer(url: url, title: query.title, durationSeconds: nil,
                isFile: AppleServerTrailerStreamPolicy.playsAsFile(container: url.pathExtension)), answered: true)
        }
        if let reference = AppleMediaServerItemReference.parse(query.mediaID) {
            guard let session = sessions[reference.sourceID] else { return Lookup(trailer: nil, answered: true) }
            do { return Lookup(trailer: try await firstTrailer(session: session, itemID: reference.itemID), answered: true) }
            catch { return Lookup(trailer: nil, answered: false) }
        }
        guard query.imdbID != nil || query.tmdbID != nil || query.year != nil else { return Lookup(trailer: nil, answered: true) }
        var answered = true
        for (_, session) in sessions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !Task.isCancelled else { return Lookup(trailer: nil, answered: false) }
            do {
                guard let match = AppleServerTrailerMatch.best(try await searchCandidates(session: session, query: query),
                                                               for: query) else { continue }
                if let trailer = try await firstTrailer(session: session, itemID: match.id) {
                    return Lookup(trailer: trailer, answered: true)
                }
            } catch {
                answered = false
            }
        }
        return Lookup(trailer: nil, answered: answered)
    }

    private func searchCandidates(session: AppleMediaServerSession,
                                  query: AppleServerTrailerQuery) async throws -> [AppleServerTrailerMatch.Candidate] {
        session.kind == .plex
            ? try await plexClient.searchCandidates(session: session, query: query)
            : try await client.searchCandidates(session: session, query: query)
    }

    private func firstTrailer(session: AppleMediaServerSession, itemID: String) async throws -> AppleServerTrailer? {
        session.kind == .plex
            ? try await plexClient.trailers(session: session, ratingKey: itemID).first
            : try await client.firstTrailer(session: session, itemID: itemID)
    }
}
