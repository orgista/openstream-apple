#if DEBUG
import Foundation

public enum AppleSavedSourceDiagnosticProbeKind: String, Codable, CaseIterable, Sendable {
    case iptv
    case smb
    case streamingAddon
    case arr
    case search
    case trailer
}

public enum AppleSavedSourceDiagnosticStage: String, Codable, CaseIterable, Sendable {
    case authenticate
    case categories
    case channels
    case guide
    case playbackRequest
    case headers
    case dnsSD
    case browse
    case firstRead
    case rangeRead
    case manifest
    case catalog
    case meta
    case streamClassification
    case library
    case roots
    case profiles
    case lookup
    case firstResultTiming
    case timing
    case audio
    case captions
    case playButton
}

public enum AppleSavedSourceDiagnosticStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case blocked = "BLOCKED"
}

public struct AppleSavedSourceDiagnosticResult: Codable, Equatable, Sendable {
    public let probeKind: AppleSavedSourceDiagnosticProbeKind
    public let stage: AppleSavedSourceDiagnosticStage
    public let durationMilliseconds: Int
    public let status: AppleSavedSourceDiagnosticStatus
    public let errorCategory: String?

    public init(
        probeKind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage,
        durationMilliseconds: Int,
        status: AppleSavedSourceDiagnosticStatus,
        errorCategory: String? = nil
    ) {
        self.probeKind = probeKind
        self.stage = stage
        self.durationMilliseconds = max(durationMilliseconds, 0)
        self.status = status
        self.errorCategory = errorCategory
    }
}

public enum AppleSavedSourceDiagnosticsLaunch {
    public static let argument = "--openstream-diagnostics"

    public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(argument)
    }
}

public protocol AppleSavedSourceDiagnosticsOperations: Sendable {
    func run(
        kind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage
    ) async throws
}

public enum AppleSavedSourceDiagnosticsError: Error, Equatable, Sendable {
    case noConfiguredSource
    case noStreamProvider
    case noResult
    case emptyStreamResponse
    case externalStream
    case torrentStream
    case youtubeStream
    case malformedStream
    case unsupportedStage
    case fixtureFailure
    case timeout
}

public struct AppleSavedSourceDiagnosticsRunner: Sendable {
    public typealias Clock = @Sendable () -> Date

    private let operations: any AppleSavedSourceDiagnosticsOperations
    private let now: Clock

    public init(
        operations: any AppleSavedSourceDiagnosticsOperations,
        now: @escaping Clock = { Date() }
    ) {
        self.operations = operations
        self.now = now
    }

    public func run(timeout: Duration = .seconds(20)) async -> [AppleSavedSourceDiagnosticResult] {
        var results: [AppleSavedSourceDiagnosticResult] = []
        for (kind, stages) in Self.plan {
            for stage in stages {
                results.append(await run(kind: kind, stage: stage, timeout: timeout))
            }
        }
        return results
    }

    private func run(
        kind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage,
        timeout: Duration
    ) async -> AppleSavedSourceDiagnosticResult {
        let startedAt = now()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await operations.run(kind: kind, stage: stage) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AppleSavedSourceDiagnosticsError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
            return result(kind: kind, stage: stage, startedAt: startedAt, status: .pass)
        } catch AppleSavedSourceDiagnosticsError.timeout {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .fail,
                errorCategory: "timeout"
            )
        } catch AppleSavedSourceDiagnosticsError.noConfiguredSource {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "not-configured"
            )
        } catch AppleSavedSourceDiagnosticsError.unsupportedStage {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "unsupported"
            )
        } catch AppleSavedSourceDiagnosticsError.noStreamProvider {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "no-stream-provider"
            )
        } catch AppleSavedSourceDiagnosticsError.externalStream {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "external-link"
            )
        } catch AppleSavedSourceDiagnosticsError.torrentStream {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "torrent-service-required"
            )
        } catch AppleSavedSourceDiagnosticsError.youtubeStream {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "youtube-link"
            )
        } catch AppleSavedSourceDiagnosticsError.emptyStreamResponse {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .fail,
                errorCategory: "empty-streams"
            )
        } catch AppleSavedSourceDiagnosticsError.malformedStream {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .fail,
                errorCategory: "malformed-stream"
            )
        } catch is CancellationError {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .blocked,
                errorCategory: "cancelled"
            )
        } catch {
            return result(
                kind: kind,
                stage: stage,
                startedAt: startedAt,
                status: .fail,
                errorCategory: Self.errorCategory(for: error)
            )
        }
    }

    private func result(
        kind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage,
        startedAt: Date,
        status: AppleSavedSourceDiagnosticStatus,
        errorCategory: String? = nil
    ) -> AppleSavedSourceDiagnosticResult {
        AppleSavedSourceDiagnosticResult(
            probeKind: kind,
            stage: stage,
            durationMilliseconds: Int(max(0, now().timeIntervalSince(startedAt) * 1_000)),
            status: status,
            errorCategory: errorCategory
        )
    }

    private static func errorCategory(for error: Error) -> String {
        if error is URLError { return "network" }
        if error is AppleIPTVError || error is AppleSMBError || error is AppleArrClientError {
            return "provider"
        }
        if error is AppleStremioPlaybackError || error is AppleManifestClientError {
            return "provider"
        }
        return "unknown"
    }

    private static let plan: [(AppleSavedSourceDiagnosticProbeKind, [AppleSavedSourceDiagnosticStage])] = [
        (.iptv, [.authenticate, .categories, .channels, .guide, .playbackRequest, .headers]),
        (.smb, [.dnsSD, .authenticate, .browse, .firstRead, .rangeRead]),
        (.streamingAddon, [.manifest, .catalog, .meta, .streamClassification]),
        (.arr, [.authenticate, .library, .roots, .profiles, .lookup]),
        (.search, [.firstResultTiming]),
        (.trailer, [.timing, .audio, .captions, .playButton]),
    ]
}

public enum AppleSavedSourceDiagnosticsConsole {
    public static func summary(_ results: [AppleSavedSourceDiagnosticResult]) -> String {
        let values = results.map { result in
            let category = result.errorCategory ?? "none"
            return "\(result.probeKind.rawValue).\(result.stage.rawValue)=\(result.status.rawValue):\(result.durationMilliseconds):\(category)"
        }
        return "OpenStream diagnostics [\(values.joined(separator: ","))]"
    }
}

/// Production adapter for the DEBUG diagnostics launch argument. It reuses
/// the same stores, Keychain references, and network clients as the app UI.
public struct AppleSavedSourceDiagnosticsProductionOperations: AppleSavedSourceDiagnosticsOperations, Sendable {
    private let sources: [AppleSource]
    private let iptvCredentials: [AppleSource.ID: AppleIPTVCredentials]
    private let networkCredentials: [AppleSource.ID: AppleSMBCredentials]
    private let radarrURL: String
    private let radarrAPIKey: String
    private let sonarrURL: String
    private let sonarrAPIKey: String

    @MainActor
    public init(sourceStore: AppleSourceStore, settings: AppleSettingsStore) {
        sources = sourceStore.sources
        var loadedIPTVCredentials: [AppleSource.ID: AppleIPTVCredentials] = [:]
        var loadedNetworkCredentials: [AppleSource.ID: AppleSMBCredentials] = [:]
        for source in sourceStore.sources {
            if let credentials = try? sourceStore.iptvCredentials(for: source) {
                loadedIPTVCredentials[source.id] = credentials
            }
            if let credentials = try? sourceStore.networkCredentials(for: source) {
                loadedNetworkCredentials[source.id] = credentials
            }
        }
        iptvCredentials = loadedIPTVCredentials
        networkCredentials = loadedNetworkCredentials
        radarrURL = settings.radarrURL
        radarrAPIKey = settings.radarrAPIKey
        sonarrURL = settings.sonarrURL
        sonarrAPIKey = settings.sonarrAPIKey
    }

    public func run(
        kind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage
    ) async throws {
        switch kind {
        case .iptv:
            try await runIPTV(stage: stage)
        case .smb:
            try await runSMB(stage: stage)
        case .streamingAddon:
            try await runStreamingAddon(stage: stage)
        case .arr:
            try await runARR(stage: stage)
        case .search:
            guard sources.contains(where: { $0.isEnabled }) else {
                throw AppleSavedSourceDiagnosticsError.noConfiguredSource
            }
        case .trailer:
            guard AppleTrailerPreviewPolicy.shouldAutoplay(
                reduceMotion: false,
                systemVideoAutoplayEnabled: true
            ), AppleTrailerPreviewPolicy.embedURL(for: "fixtureTrailer") != nil else {
                throw AppleSavedSourceDiagnosticsError.noResult
            }
        }
    }

    private func runIPTV(stage: AppleSavedSourceDiagnosticStage) async throws {
        guard let source = sources.first(where: { $0.kind == .liveTV && $0.isEnabled }),
              let type = source.iptvType else {
            throw AppleSavedSourceDiagnosticsError.noConfiguredSource
        }
        let credentials = iptvCredentials[source.id]
        let client = AppleIPTVClient()
        let channels = try await client.channels(source: source, credentials: credentials)
        guard let channel = channels.first else { throw AppleSavedSourceDiagnosticsError.noResult }
        switch stage {
        case .playbackRequest:
            _ = try await client.playbackURL(for: channel)
        case .headers:
            guard !channel.playbackHeaders.isEmpty else { throw AppleSavedSourceDiagnosticsError.noResult }
        case .authenticate, .categories, .channels, .guide:
            if type == .xtream { guard credentials != nil else { throw AppleSavedSourceDiagnosticsError.noConfiguredSource } }
        default:
            throw AppleSavedSourceDiagnosticsError.unsupportedStage
        }
    }

    private func runSMB(stage: AppleSavedSourceDiagnosticStage) async throws {
        guard let source = sources.first(where: { $0.kind == .nas && $0.isEnabled }) else {
            throw AppleSavedSourceDiagnosticsError.noConfiguredSource
        }
        let parts = try AppleSMBEndpointPolicy.parts(from: source.url)
        let credentials = networkCredentials[source.id]
            ?? AppleSMBCredentials(username: "", password: "")
        let client = AppleSMBClient()
        switch stage {
        case .dnsSD:
            guard let service = AppleSMBEndpointPolicy.bonjourService(from: parts.host),
                  await AppleSMBDiscovery().resolve(service: service) != nil else {
                throw AppleSavedSourceDiagnosticsError.noResult
            }
        case .authenticate:
            _ = try await client.listShares(host: parts.host, port: parts.port, credentials: credentials)
        case .browse:
            _ = try await client.listDirectory(url: source.url, credentials: credentials, recursive: false)
        case .firstRead, .rangeRead:
            let entries = try await client.listDirectory(url: source.url, credentials: credentials, recursive: false)
            guard let file = entries.first(where: { !$0.isDirectory }) else {
                throw AppleSavedSourceDiagnosticsError.noResult
            }
            let fileURL = try AppleSMBEndpointPolicy.makeURL(
                host: parts.host,
                port: parts.port,
                share: parts.share,
                path: file.path
            )
            let range: Range<UInt64> = stage == .firstRead ? 0 ..< 1_024 : 1_024 ..< 2_048
            _ = try await client.read(url: fileURL, credentials: credentials, range: range)
        default:
            throw AppleSavedSourceDiagnosticsError.unsupportedStage
        }
    }

    private func runStreamingAddon(stage: AppleSavedSourceDiagnosticStage) async throws {
        guard let source = sources.first(where: { $0.kind == .stremio && $0.isEnabled }) else {
            throw AppleSavedSourceDiagnosticsError.noConfiguredSource
        }
        switch stage {
        case .manifest:
            _ = try await AppleManifestClient().load(source.url.absoluteString)
        case .catalog:
            guard let catalog = source.catalogs.first(where: { !$0.requiresInput }) else {
                throw AppleSavedSourceDiagnosticsError.noResult
            }
            _ = try await AppleStremioCatalogClient().load(source: source, catalog: catalog)
        case .meta:
            guard await AppleStremioMetadataClient().previewAssets(
                sources: [source],
                type: "movie",
                mediaID: "tt0000001"
            ) != nil else {
                throw AppleSavedSourceDiagnosticsError.noResult
            }
        case .streamClassification:
            guard let source = Self.firstStreamSource(in: sources) else {
                throw AppleSavedSourceDiagnosticsError.noStreamProvider
            }
            let selection = try await AppleStremioPlaybackClient().streams(
                source: source,
                type: "movie",
                mediaID: "tt0000001"
            )
            try Self.validateStreamClassification(selection)
        default:
            throw AppleSavedSourceDiagnosticsError.unsupportedStage
        }
    }

    static func firstStreamSource(in sources: [AppleSource]) -> AppleSource? {
        sources.first {
            $0.kind == .stremio
                && $0.isEnabled
                && $0.resources.contains { $0.caseInsensitiveCompare("stream") == .orderedSame }
        }
    }

    static func validateStreamClassification(_ selection: AppleStremioStreamSelection) throws {
        guard selection.httpCandidates.isEmpty else { return }
        guard let unsupported = selection.unsupported.first else {
            throw AppleSavedSourceDiagnosticsError.emptyStreamResponse
        }
        switch unsupported.reason {
        case .torrent:
            throw AppleSavedSourceDiagnosticsError.torrentStream
        case .externalLink:
            throw AppleSavedSourceDiagnosticsError.externalStream
        case .youtube:
            throw AppleSavedSourceDiagnosticsError.youtubeStream
        case .invalidHTTPURL, .invalidLocator, .missingLocator:
            throw AppleSavedSourceDiagnosticsError.malformedStream
        }
    }

    private func runARR(stage: AppleSavedSourceDiagnosticStage) async throws {
        let values: [(AppleArrKind, String, String)] = [
            (.radarr, radarrURL, radarrAPIKey),
            (.sonarr, sonarrURL, sonarrAPIKey),
        ]
        guard let (kind, baseURL, apiKey) = values.first(where: {
            !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && AppleArrClient.isValidAPIKey($0.2)
        }) else {
            throw AppleSavedSourceDiagnosticsError.noConfiguredSource
        }
        let client = AppleArrClient()
        switch stage {
        case .authenticate:
            _ = try await client.test(kind: kind, baseURL: baseURL, apiKey: apiKey)
        case .library:
            _ = try await client.library(kind: kind, baseURL: baseURL, apiKey: apiKey)
        case .roots, .profiles, .lookup:
            throw AppleSavedSourceDiagnosticsError.unsupportedStage
        default:
            throw AppleSavedSourceDiagnosticsError.unsupportedStage
        }
    }
}
#endif
