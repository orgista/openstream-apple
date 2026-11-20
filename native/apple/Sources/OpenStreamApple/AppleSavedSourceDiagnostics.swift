import Foundation

public enum AppleSavedSourceDiagnosticProbeKind: String, Codable, CaseIterable, Sendable {
    case iptv
    case smb
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
    case firstResultTiming
    case timing
    case audio
    case captions
    case playButton
}

#if DEBUG
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
    case noResult
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
        if error is AppleIPTVError || error is AppleSMBError {
            return "provider"
        }
        return "unknown"
    }

    private static let plan: [(AppleSavedSourceDiagnosticProbeKind, [AppleSavedSourceDiagnosticStage])] = [
        (.iptv, [.authenticate, .categories, .channels, .guide, .playbackRequest, .headers]),
        (.smb, [.dnsSD, .authenticate, .browse, .firstRead, .rangeRead]),
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

    @MainActor
    public init(sourceStore: AppleSourceStore) {
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
}
#endif
