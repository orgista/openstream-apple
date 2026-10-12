#if OPENSTREAM_ADDONS
import Foundation
import Synchronization

// Shared shapes between the sweep driver and the per-add-on probe process.
// Everything here is plain data: the probe writes one `AddonResult` as JSON on
// stdout and the driver reads it back. Nothing in these types ever carries a
// manifest URL, so a private (configured) add-on's key cannot leak through them.

struct ProbeJob: Codable, Sendable {
    var index: Int
    var name: String
    var manifestURL: String
    /// `needs_config` add-ons: only the manifest stage runs.
    var manifestOnly: Bool
    var isPrivate: Bool
    /// Self-test: trap inside the catalog stage to prove crash attribution.
    var selfTestTrap: Bool = false
}

enum StageStatus: String, Codable, Sendable {
    case pass
    /// The request succeeded but the app got nothing usable out of it.
    case empty
    case fail
    case timeout
    case skip
    case crash
    case notRun
}

struct StageOutcome: Codable, Sendable {
    var status: StageStatus
    /// Machine-groupable reason, e.g. `http:404`, `transport:timedOut`,
    /// `decode:meta:id-mismatch`, `bad-response:not-json`.
    var cause: String?
    /// Short human detail for the report table.
    var detail: String?

    static func skip(_ why: String) -> StageOutcome { .init(status: .skip, cause: nil, detail: why) }
    static let notRun = StageOutcome(status: .notRun, cause: nil, detail: nil)
}

struct ManifestInfo: Codable, Sendable {
    var id: String?
    var version: String?
    /// Resources as the app kept them.
    var appResources: [String] = []
    /// Resource names as the add-on declared them.
    var rawResources: [String] = []
    var types: [String] = []
    var idPrefixes: [String] = []
    var rawCatalogCount = 0
    /// Catalogs the app keeps after its movie/series filter and 12-catalog cap.
    var appCatalogCount = 0
    /// Catalogs the Discover shelves would load (no required extras).
    var eligibleCatalogCount = 0
    var requiredExtraCatalogCount = 0
    /// Raw catalog types the app ignores (e.g. `tv`, `channel`, `anime`) → count.
    var ignoredCatalogTypes: [String: Int] = [:]
    /// `AppleAddonURLSecretPolicy.isSecret` on the normalized manifest URL.
    var treatedAsSecret: Bool?
    var specValid: Bool?
}

struct CatalogProbe: Codable, Sendable {
    var type: String
    var id: String
    var outcome: StageOutcome
    var httpStatus: Int?
    var rawCount: Int?
    var decodedCount: Int?
    /// Raw metas the app dropped, by first failing reason.
    var dropReasons: [String: Int] = [:]
}

struct MetaProbe: Codable, Sendable {
    var type: String
    var idPrefix: String
    var fromCatalog: Bool
    var outcome: StageOutcome
    var httpStatus: Int?
    var episodes: StageOutcome?
    var episodeCount: Int?
}

struct StreamProbe: Codable, Sendable {
    var type: String
    var mediaID: String
    var outcome: StageOutcome
    var httpStatus: Int?
    var rawCount: Int?
    var httpCandidates: Int?
    var unsupported: [String: Int] = [:]
}

struct SubtitleProbe: Codable, Sendable {
    var outcome: StageOutcome
    var httpStatus: Int?
    var rawCount: Int?
    var parsedTracks: Int?
    var englishTracksFromService: Int?
}

struct AddonResult: Codable, Sendable {
    var index: Int
    var name: String
    var manifest: StageOutcome = .notRun
    var manifestInfo: ManifestInfo?
    var catalogs: StageOutcome = .notRun
    var catalogProbes: [CatalogProbe] = []
    var meta: StageOutcome = .notRun
    var metaProbe: MetaProbe?
    var streams: StageOutcome = .notRun
    var streamProbes: [StreamProbe] = []
    var subtitles: StageOutcome = .notRun
    var subtitleProbe: SubtitleProbe?
    /// Compatibility gaps that are not failures (ignored catalog types, …).
    var notes: [String] = []
}

/// One recorded HTTP exchange, kept only inside the probe process so the
/// classifier can explain *why* the app's client rejected a response.
struct RecordedExchange: Sendable {
    var requestURL: URL?
    var responseURL: URL?
    var status: Int?
    var contentType: String?
    var body: Data?
    var error: String?
}

final class ExchangeRecorder: Sendable {
    private let storage = Mutex<[RecordedExchange]>([])

    func append(_ exchange: RecordedExchange) {
        storage.withLock { $0.append(exchange) }
    }

    var last: RecordedExchange? { storage.withLock { $0.last } }
    var lastResponse: RecordedExchange? { storage.withLock { $0.last(where: { $0.status != nil }) } }

    func reset() { storage.withLock { $0.removeAll() } }

    typealias RequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias URLLoader = @Sendable (URL) async throws -> (Data, URLResponse)

    func wrap(_ base: @escaping RequestLoader) -> RequestLoader {
        { [self] request in
            do {
                let (data, response) = try await base(request)
                record(request.url, response, data)
                return (data, response)
            } catch {
                append(RecordedExchange(requestURL: request.url, error: Classifier.cause(of: error)))
                throw error
            }
        }
    }

    func wrap(_ base: @escaping URLLoader) -> URLLoader {
        { [self] url in
            do {
                let (data, response) = try await base(url)
                record(url, response, data)
                return (data, response)
            } catch {
                append(RecordedExchange(requestURL: url, error: Classifier.cause(of: error)))
                throw error
            }
        }
    }

    private func record(_ url: URL?, _ response: URLResponse, _ data: Data) {
        let http = response as? HTTPURLResponse
        append(RecordedExchange(
            requestURL: url,
            responseURL: response.url,
            status: http?.statusCode,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            body: data
        ))
    }
}

struct ProbeTimeout: Error {}

/// Runs `operation` with a wall-clock limit. The app's loaders set a 15 s
/// request timeout but retry up to four times, so each stage gets its own cap.
func withStageTimeout<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw ProbeTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ProbeTimeout() }
        return first
    }
}

#endif
