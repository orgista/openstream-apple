import Foundation

/// The SPARQL query for streaming ids, and its answer.
///
/// Privacy: the request carries IMDb ids and constant query text, nothing
/// else — no account, region, provider list or user id (spec §5).
public enum AppleWikidataStreamingQuery {
    public static let endpoint = URL(string: "https://query.wikidata.org/sparql")!
    /// Wikimedia's query service limit is generous; 50 keeps the GET short.
    public static let batchLimit = 50

    /// Only `tt` + digits ever reaches the query, so nothing can be injected.
    public static func isIMDbID(_ id: String) -> Bool {
        id.range(of: #"^tt\d{1,10}$"#, options: .regularExpression) != nil
    }

    /// One `SELECT` for up to `batchLimit` ids: every property in
    /// `AppleWikidataStreamingProperty`, `|`-joined per id. Nil when no id is
    /// valid.
    public static func sparql(imdbIDs: [String]) -> String? {
        var seen = Set<String>()
        let ids = imdbIDs.filter { isIMDbID($0) && seen.insert($0).inserted }.prefix(batchLimit)
        guard !ids.isEmpty else { return nil }
        let properties = AppleWikidataStreamingProperty.allCases.map(\.rawValue)
        let select = properties
            .map { "(GROUP_CONCAT(DISTINCT ?v_\($0);separator=\"|\") AS ?\($0))" }
            .joined(separator: " ")
        let optionals = properties
            .map { "OPTIONAL { ?item wdt:\($0) ?v_\($0) }" }
            .joined(separator: " ")
        let values = ids.map { "\"\($0)\"" }.joined(separator: " ")
        return "SELECT ?imdb \(select) WHERE { VALUES ?imdb { \(values) } ?item wdt:P345 ?imdb . \(optionals) } GROUP BY ?imdb"
    }

    /// The GET request: query, JSON accept header, and a User-Agent with a
    /// contact URL, which Wikimedia's policy asks for (calls without one were
    /// rate-limited within seconds in the research).
    public static func request(imdbIDs: [String], version: String = appVersion) -> URLRequest? {
        guard let query = sparql(imdbIDs: imdbIDs) else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "OpenStream/\(version) (+https://orgista.com/support)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private struct Response: Decodable {
        struct Results: Decodable { let bindings: [[String: Value]] }
        struct Value: Decodable { let value: String }
        let results: Results
    }

    /// IMDb id → its ids. A requested id Wikidata does not know is absent
    /// here; the caller records it as a miss.
    public static func parse(_ data: Data) throws -> [String: AppleStreamingIDs] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result: [String: AppleStreamingIDs] = [:]
        for binding in response.results.bindings {
            guard let imdb = binding["imdb"]?.value, isIMDbID(imdb) else { continue }
            var values: [String: [String]] = [:]
            for property in AppleWikidataStreamingProperty.allCases {
                let split = (binding[property.rawValue]?.value ?? "")
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !split.isEmpty { values[property.rawValue] = split }
            }
            result[imdb] = AppleStreamingIDs(values: values)
        }
        return result
    }
}

/// On-disk cache of looked-up ids, keyed by IMDb id. Hits keep 7 days and
/// misses 1 day, because Wikidata gets edited.
struct AppleStreamingIDCache {
    static let hitLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let missLifetime: TimeInterval = 24 * 60 * 60
    static let entryLimit = 2_000

    struct Entry: Codable, Equatable {
        var ids: AppleStreamingIDs
        var fetchedAt: Date
    }

    let fileURL: URL?
    private(set) var entries: [String: Entry]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            // Missing or corrupt: start over rather than fail.
            entries = [:]
        }
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("wikidata-streaming-ids.json")
    }

    static func isFresh(_ entry: Entry, now: Date) -> Bool {
        let lifetime = entry.ids.isEmpty ? missLifetime : hitLifetime
        return now.timeIntervalSince(entry.fetchedAt) < lifetime
    }

    func lookup(_ imdbID: String, now: Date) -> AppleStreamingIDs? {
        guard let entry = entries[imdbID], Self.isFresh(entry, now: now) else { return nil }
        return entry.ids
    }

    mutating func store(_ ids: [String: AppleStreamingIDs], now: Date) {
        for (imdbID, value) in ids { entries[imdbID] = Entry(ids: value, fetchedAt: now) }
        entries = entries.filter { Self.isFresh($0.value, now: now) }
        if entries.count > Self.entryLimit {
            let keep = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(Self.entryLimit)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Looks up per-service title ids on Wikidata.
///
/// One request in flight app-wide, 20 s timeout, and a 429/503 backs off for
/// `Retry-After` (default 60 s, doubling on repeats). Any failure answers
/// "no ids" so the button falls back to search or home; nothing retries in a
/// loop from the UI.
public actor AppleWikidataStreamingIDClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let shared = AppleWikidataStreamingIDClient()

    static let defaultBackoff: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 60 * 60

    private let transport: Transport
    private let now: @Sendable () -> Date
    private var cache: AppleStreamingIDCache
    private var pending: [String: Task<[String: AppleStreamingIDs], Never>] = [:]
    private var tail: Task<Void, Never>?
    private var blockedUntil: Date?
    private var consecutiveRateLimits = 0

    init(
        cacheFileURL: URL? = AppleStreamingIDCache.defaultFileURL,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.transport = transport
        self.now = now
        self.cache = AppleStreamingIDCache(fileURL: cacheFileURL)
    }

    /// One title's ids; empty when Wikidata has none or cannot be reached.
    public func ids(for imdbID: String) async -> AppleStreamingIDs {
        await ids(for: [imdbID])[imdbID] ?? AppleStreamingIDs()
    }

    /// Several titles' ids in one request (cached ones are not asked again).
    public func ids(for imdbIDs: [String]) async -> [String: AppleStreamingIDs] {
        let valid = Array(Set(imdbIDs.filter(AppleWikidataStreamingQuery.isIMDbID)))
        var result: [String: AppleStreamingIDs] = [:]
        var waiting: [Task<[String: AppleStreamingIDs], Never>] = []
        var missing: [String] = []
        for id in valid {
            if let cached = cache.lookup(id, now: now()) {
                result[id] = cached
            } else if let task = pending[id] {
                waiting.append(task)
            } else {
                missing.append(id)
            }
        }
        for batch in stride(from: 0, to: missing.count, by: AppleWikidataStreamingQuery.batchLimit).map({
            Array(missing[$0 ..< min($0 + AppleWikidataStreamingQuery.batchLimit, missing.count)])
        }) {
            let previous = tail
            let task = Task { () -> [String: AppleStreamingIDs] in
                await previous?.value
                return await self.fetch(batch)
            }
            tail = Task { _ = await task.value }
            for id in batch { pending[id] = task }
            waiting.append(task)
        }
        for task in waiting {
            let fetched = await task.value
            for id in valid where result[id] == nil {
                if let value = fetched[id] { result[id] = value }
            }
        }
        return result
    }

    /// Whether a rate limit is holding requests back (for tests).
    var isBackingOff: Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > now()
    }

    private func fetch(_ batch: [String]) async -> [String: AppleStreamingIDs] {
        defer { for id in batch { pending[id] = nil } }
        if let blockedUntil, blockedUntil > now() { return [:] }
        guard let request = AppleWikidataStreamingQuery.request(imdbIDs: batch) else { return [:] }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            appleTrace("watch-on: wikidata lookup failed (\(batch.count) ids)")
            return [:]
        }
        guard let http = response as? HTTPURLResponse else { return [:] }
        if http.statusCode == 429 || http.statusCode == 503 {
            consecutiveRateLimits += 1
            let retryAfter = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now())
            let backoff = min(
                Self.maximumBackoff,
                max(retryAfter ?? Self.defaultBackoff,
                    Self.defaultBackoff * pow(2, Double(consecutiveRateLimits - 1)))
            )
            blockedUntil = now().addingTimeInterval(backoff)
            appleTrace("watch-on: wikidata \(http.statusCode), backing off \(Int(backoff)) s")
            return [:]
        }
        guard http.statusCode == 200, let parsed = try? AppleWikidataStreamingQuery.parse(data) else {
            appleTrace("watch-on: wikidata answered \(http.statusCode)")
            return [:]
        }
        consecutiveRateLimits = 0
        blockedUntil = nil
        // Every id asked for is recorded: a title Wikidata does not know is a
        // miss, kept for a day.
        var answered: [String: AppleStreamingIDs] = [:]
        for id in batch { answered[id] = parsed[id] ?? AppleStreamingIDs() }
        cache.store(answered, now: now())
        return answered
    }

    /// `Retry-After` in seconds or as an HTTP date.
    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
