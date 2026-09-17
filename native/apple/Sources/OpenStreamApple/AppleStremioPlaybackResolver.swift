import Foundation

public struct AppleResolvedStremioPlayback: Equatable, Sendable {
    public let sourceName: String
    public let stream: AppleStremioHTTPPlaybackCandidate
    public let preparedPlayback: ApplePreparedPlayback

    public init(
        stream: AppleStremioHTTPPlaybackCandidate,
        preparedPlayback: ApplePreparedPlayback,
        sourceName: String = ""
    ) {
        self.sourceName = sourceName
        self.stream = stream
        self.preparedPlayback = preparedPlayback
    }
}

public enum AppleStremioPlaybackResolutionError: Swift.Error, Equatable, LocalizedError, Sendable {
    case noStreams
    case unsupportedOnly(AppleStremioUnsupportedReason)
    case externalDemuxRequired
    case gatewayUnavailable
    case noCompatibleHTTPStream
    case providerFailure(ApplePlaybackFailure)

    public var errorDescription: String? {
        switch self {
        case .noStreams:
            "No streams available."
        case .unsupportedOnly(let reason):
            switch reason {
            case .torrent:
                "Torrent resolver required."
            case .externalLink:
                "External link only."
            case .youtube:
                "YouTube link only."
            case .invalidHTTPURL, .invalidLocator, .missingLocator:
                "No playable stream."
            }
        case .externalDemuxRequired:
            "External demuxer required."
        case .gatewayUnavailable:
            "Gateway unavailable."
        case .noCompatibleHTTPStream:
            "No Apple-compatible stream was found."
        case .providerFailure(let failure):
            failure.message
        }
    }
}

/// Coordinates the protocol client with AVAsset runtime inspection and the
/// existing playback route executor. Provider ordering is preserved: each
/// HTTP candidate is tried until one produces a real prepared playback URL.
public struct AppleStremioPlaybackResolver: Sendable {
    public typealias Inspector = @Sendable (URL) async throws -> AppleAssetInspection
    public typealias Preparer = @Sendable (
        URL,
        OpenStreamPlaybackDecision,
        AppleAssetInspection,
        AppleGatewayTranscodeRequest?
    ) async throws -> ApplePreparedPlayback
    public typealias ProtectedPlaybackRevoker = @Sendable (URL) async -> Void

    private let client: AppleStremioPlaybackClient
    private let streamingServerClient: AppleStremioStreamingServerClient
    private let inspector: Inspector
    private let preparer: Preparer
    private let protectedPlaybackURL: AppleIPTVClient.ProtectedPlaybackURL
    private let revokeProtectedPlaybackURL: ProtectedPlaybackRevoker
    private let resolutionTimeout: Duration
    private let sourceTimeout: Duration

    public init(
        client: AppleStremioPlaybackClient = AppleStremioPlaybackClient(),
        inspector: @escaping Inspector = { try await AppleAssetInspector.inspect(url: $0) },
        playbackPreparer: ApplePlaybackPreparer = ApplePlaybackPreparer(),
        protectedPlaybackURL: @escaping AppleIPTVClient.ProtectedPlaybackURL = AppleIPTVClient.liveProtectedPlaybackURL,
        revokeProtectedPlaybackURL: @escaping ProtectedPlaybackRevoker = {
            AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: $0)
        },
        streamingServerClient: AppleStremioStreamingServerClient = AppleStremioStreamingServerClient(),
        resolutionTimeout: Duration = .seconds(45),
        sourceTimeout: Duration = .seconds(15)
    ) {
        self.client = client
        self.streamingServerClient = streamingServerClient
        self.inspector = inspector
        preparer = { sourceURL, decision, inspection, gatewayRequest in
            try await playbackPreparer.prepare(
                sourceURL: sourceURL,
                decision: decision,
                inspectedAsset: inspection,
                gatewayRequest: gatewayRequest
            )
        }
        self.protectedPlaybackURL = protectedPlaybackURL
        self.revokeProtectedPlaybackURL = revokeProtectedPlaybackURL
        self.resolutionTimeout = max(resolutionTimeout, .milliseconds(1))
        self.sourceTimeout = max(sourceTimeout, .milliseconds(1))
    }

    public init(
        client: AppleStremioPlaybackClient,
        inspector: @escaping Inspector,
        preparer: @escaping Preparer,
        protectedPlaybackURL: @escaping AppleIPTVClient.ProtectedPlaybackURL = AppleIPTVClient.liveProtectedPlaybackURL,
        revokeProtectedPlaybackURL: @escaping ProtectedPlaybackRevoker = {
            AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: $0)
        },
        streamingServerClient: AppleStremioStreamingServerClient = AppleStremioStreamingServerClient(),
        resolutionTimeout: Duration = .seconds(45),
        sourceTimeout: Duration = .seconds(15)
    ) {
        self.client = client
        self.streamingServerClient = streamingServerClient
        self.inspector = inspector
        self.preparer = preparer
        self.protectedPlaybackURL = protectedPlaybackURL
        self.revokeProtectedPlaybackURL = revokeProtectedPlaybackURL
        self.resolutionTimeout = max(resolutionTimeout, .milliseconds(1))
        self.sourceTimeout = max(sourceTimeout, .milliseconds(1))
    }

    public func resolve(
        source: AppleSource,
        item: AppleCatalogItem,
        gatewayConfig: AppleTranscodeGatewayConfig? = nil,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration? = nil,
        progress: (@Sendable (ApplePlaybackPhase) async -> Void)? = nil
    ) async throws -> AppleResolvedStremioPlayback {
        await progress?(.resolving)
        let selection = try await client.streams(
            source: source,
            type: item.type,
            mediaID: item.mediaID
        )
        guard !selection.httpCandidates.isEmpty || !selection.unsupported.isEmpty else {
            throw AppleStremioPlaybackResolutionError.noStreams
        }

        var state = CandidateResolutionState()
        let httpCandidates = Array(selection.httpCandidates.prefix(12))
        if !httpCandidates.isEmpty {
            // AVFoundation can spend its full inspection deadline on a dead
            // provider URL. Inspecting candidates strictly one at a time made
            // a valid sixth result take roughly 40–50 seconds to reach the
            // player. Keep the fan-out bounded for mobile hardware, but accept
            // the first candidate that completes the full preparation path.
            await progress?(.loading)
            let candidateResult = try await resolveFirstPreparedCandidate(
                httpCandidates,
                gatewayConfig: gatewayConfig
            )
            state = candidateResult.state
            if let resolved = candidateResult.resolved {
                return AppleResolvedStremioPlayback(stream: resolved.stream, preparedPlayback: resolved.preparedPlayback, sourceName: source.name)
            }
        }

        if let streamingServerConfiguration {
            for unsupported in selection.unsupported.prefix(6) {
                guard case .torrent(let infoHash, let fileIndex, let sources) = unsupported.reason else {
                    continue
                }
                let generated: [AppleStremioHTTPPlaybackCandidate]
                do {
                    generated = try await streamingServerClient.playbackCandidates(
                        title: unsupported.title,
                        filename: unsupported.filename,
                        infoHash: infoHash,
                        fileIndex: fileIndex,
                        sources: sources,
                        seriesInfo: AppleStremioSeriesInfo(mediaID: item.mediaID),
                        configuration: streamingServerConfiguration
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    state.record(.provider(Self.streamingServerFailure(error)))
                    break
                }

                for stream in generated {
                    try Task.checkCancellation()
                    do {
                        let resolved = try await prepare(
                            stream: stream,
                            // The configured Stremio Service is already the
                            // torrent/HLS boundary. Never forward its local or
                            // private media URL to a separate remote gateway.
                            gatewayConfig: nil,
                            progress: progress
                        )
                        return AppleResolvedStremioPlayback(stream: resolved.stream, preparedPlayback: resolved.preparedPlayback, sourceName: source.name)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as CandidateAttemptError {
                        state.record(error)
                    } catch {
                        state.record(.provider(ApplePlaybackFailure.classify(error)))
                    }
                }
            }
        }

        if let lastProviderFailure = state.lastProviderFailure {
            throw AppleStremioPlaybackResolutionError.providerFailure(lastProviderFailure)
        }

        if state.gatewayFailed {
            throw AppleStremioPlaybackResolutionError.gatewayUnavailable
        }
        if state.needsExternalDemux {
            throw AppleStremioPlaybackResolutionError.externalDemuxRequired
        }
        if selection.httpCandidates.isEmpty, let unsupported = selection.unsupported.first {
            throw AppleStremioPlaybackResolutionError.unsupportedOnly(unsupported.reason)
        }
        throw AppleStremioPlaybackResolutionError.noCompatibleHTTPStream
    }

    /// Catalog and playback resources commonly come from different add-ons.
    /// Try every enabled stream provider, preferring the catalog provider only
    /// when it can also serve streams.
    public func resolve(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        item: AppleCatalogItem,
        gatewayConfig: AppleTranscodeGatewayConfig? = nil,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration? = nil,
        progress: (@Sendable (ApplePlaybackPhase) async -> Void)? = nil
    ) async throws -> AppleResolvedStremioPlayback {
        let candidates = Self.streamSources(from: sources, preferredSourceID: preferredSourceID)
        guard !candidates.isEmpty else { throw AppleStremioPlaybackResolutionError.noStreams }

        var bestError: AppleStremioPlaybackResolutionError = .noStreams
        var lastProviderFailure: ApplePlaybackFailure?
        for source in candidates {
            try Task.checkCancellation()
            do {
                return try await resolve(
                    source: source,
                    item: item,
                    gatewayConfig: gatewayConfig,
                    streamingServerConfiguration: streamingServerConfiguration,
                    progress: progress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppleStremioPlaybackResolutionError {
                if Self.priority(of: error) > Self.priority(of: bestError) { bestError = error }
            } catch {
                lastProviderFailure = ApplePlaybackFailure.classify(error)
            }
        }
        if let lastProviderFailure { throw AppleStremioPlaybackResolutionError.providerFailure(lastProviderFailure) }
        throw bestError
    }

    /// Returns ranked HTTP candidates for an item without AVAsset inspection or
    /// route preparation. The caller builds an `ApplePlaybackRequest` from the
    /// first candidate and passes the rest as fallback candidates so the
    /// playback coordinator tries the next on `.unsupportedMedia`/HTTP failure.
    /// Torrent-only selections are expanded through the configured Stremio
    /// streaming server before ranking.
    public func rankedCandidates(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        item: AppleCatalogItem,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration? = nil
    ) async throws -> [AppleStremioHTTPPlaybackCandidate] {
        try await Self.withTimeout(resolutionTimeout) {
            try await rankedCandidatesWithinBudget(sources: sources, preferredSourceID: preferredSourceID,
                item: item, streamingServerConfiguration: streamingServerConfiguration)
        }
    }

    private func rankedCandidatesWithinBudget(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID?,
        item: AppleCatalogItem,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration?
    ) async throws -> [AppleStremioHTTPPlaybackCandidate] {
        let candidates = Self.streamSources(from: sources, preferredSourceID: preferredSourceID)
        guard !candidates.isEmpty else { throw AppleStremioPlaybackResolutionError.noStreams }

        var collected: [AppleStremioHTTPPlaybackCandidate] = []
        let started = ContinuousClock.now
        var bestError: AppleStremioPlaybackResolutionError = .noStreams
        var providerFailure: ApplePlaybackFailure?
        for source in candidates {
            try Task.checkCancellation()
            if !collected.isEmpty, started.duration(to: .now) + sourceTimeout >= resolutionTimeout { break }
            do {
                let selection = try await Self.withTimeout(sourceTimeout) {
                    try await client.streams(source: source, type: item.type, mediaID: item.mediaID)
                }
                var http = selection.httpCandidates.filter { !$0.isPendingPreparation }
                if http.isEmpty, selection.httpCandidates.contains(where: \.isPendingPreparation) {
                    providerFailure = .init(kind: .unavailable, message: "The provider is still preparing this title. No ready stream was returned.")
                }
                if let streamingServerConfiguration {
                    for unsupported in selection.unsupported.prefix(6) {
                        guard case .torrent(let infoHash, let fileIndex, let sources) = unsupported.reason else {
                            continue
                        }
                        do {
                            let generated = try await streamingServerClient.playbackCandidates(
                                title: unsupported.title,
                                filename: unsupported.filename,
                                infoHash: infoHash,
                                fileIndex: fileIndex,
                                sources: sources,
                                seriesInfo: AppleStremioSeriesInfo(mediaID: item.mediaID),
                                configuration: streamingServerConfiguration
                            )
                            http.append(contentsOf: generated)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continue
                        }
                    }
                }
                if !http.isEmpty {
                    collected += http.map { $0.withSourceName(source.name) }
                }
                if selection.httpCandidates.isEmpty, let unsupported = selection.unsupported.first {
                    let error = AppleStremioPlaybackResolutionError.unsupportedOnly(unsupported.reason)
                    if Self.priority(of: error) > Self.priority(of: bestError) { bestError = error }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A source that fails to return streams is skipped; the next
                // enabled stream source gets a chance.
                let failure = ApplePlaybackFailure.classify(error)
                if providerFailure == nil || failure.kind == .authentication {
                    providerFailure = failure
                }
            }
        }
        if !collected.isEmpty {
            // Pass the episode being played so a release naming a different one
            // cannot win on resolution alone.
            let wanted = AppleStremioSeriesInfo(mediaID: item.mediaID)
                .map { (season: $0.season, episode: $0.episode) }
            return AppleStremioCandidateRanking.rankForAutomaticPlayback(collected, episode: wanted)
        }
        if let providerFailure { throw AppleStremioPlaybackResolutionError.providerFailure(providerFailure) }
        throw bestError
    }

    private static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw URLError(.timedOut)
            }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }

    /// Resolves a durable offline source without requiring AVFoundation to
    /// inspect or play it first. Containers that need a playback gateway can
    /// still be downloaded in their original form, while provider headers are
    /// kept behind a short-lived loopback capability.
    func resolveDownloadPlan(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        item: AppleCatalogItem,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration? = nil
    ) async throws -> AppleOfflineDownloadPlan {
        let plans = try await resolveDownloadPlans(
            sources: sources,
            preferredSourceID: preferredSourceID,
            item: item,
            streamingServerConfiguration: streamingServerConfiguration
        )
        guard let selected = plans.first else {
            throw AppleStremioPlaybackResolutionError.noStreams
        }
        for unused in plans.dropFirst() {
            if let capability = unused.protectedCapabilityToRevoke {
                await revokeProtectedPlaybackURL(capability)
            }
        }
        return selected
    }

    /// Preserves the provider's ordered direct-media alternatives so the
    /// offline writer can fall through when a stale or rejected URL fails.
    /// Resolving only the first stream made Download stop after one bad mirror
    /// even though the same add-on had already supplied working alternatives.
    func resolveDownloadPlans(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        item: AppleCatalogItem,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration? = nil
    ) async throws -> [AppleOfflineDownloadPlan] {
        let candidates = Self.streamSources(from: sources, preferredSourceID: preferredSourceID)
        guard !candidates.isEmpty else { throw AppleStremioPlaybackResolutionError.noStreams }

        var bestError: AppleStremioPlaybackResolutionError = .noStreams
        var lastProviderFailure: ApplePlaybackFailure?
        for source in candidates {
            try Task.checkCancellation()
            do {
                let selection = try await client.streams(
                    source: source,
                    type: item.type,
                    mediaID: item.mediaID
                )

                var plans: [AppleOfflineDownloadPlan] = []
                // Use the same container preference as online playback so a
                // downloadable MP4 is preferred over an MKV that AVPlayer
                // may not decode once it is stored locally. Equal-container
                // candidates retain the add-on's original order.
                for stream in AppleStremioCandidateRanking.rank(selection.httpCandidates).prefix(12) {
                    do {
                        plans.append(try await downloadPlan(for: stream))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastProviderFailure = ApplePlaybackFailure.classify(error)
                    }
                }

                if !plans.isEmpty { return plans }

                if let streamingServerConfiguration {
                    for unsupported in selection.unsupported.prefix(6) {
                        guard case .torrent(let infoHash, let fileIndex, let sources) = unsupported.reason else {
                            continue
                        }
                        do {
                            let generated = try await streamingServerClient.playbackCandidates(
                                title: unsupported.title,
                                filename: unsupported.filename,
                                infoHash: infoHash,
                                fileIndex: fileIndex,
                                sources: sources,
                                seriesInfo: AppleStremioSeriesInfo(mediaID: item.mediaID),
                                configuration: streamingServerConfiguration
                            )
                            for stream in generated.prefix(12) {
                                plans.append(try await downloadPlan(for: stream))
                            }
                            if !plans.isEmpty { return plans }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            lastProviderFailure = Self.streamingServerFailure(error)
                        }
                    }
                }

                if selection.httpCandidates.isEmpty, let unsupported = selection.unsupported.first {
                    let error = AppleStremioPlaybackResolutionError.unsupportedOnly(unsupported.reason)
                    if Self.priority(of: error) > Self.priority(of: bestError) { bestError = error }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastProviderFailure = ApplePlaybackFailure.classify(error)
            }
        }
        if let lastProviderFailure {
            throw AppleStremioPlaybackResolutionError.providerFailure(lastProviderFailure)
        }
        throw bestError
    }

    public static func decision(for inspection: AppleAssetInspection) -> OpenStreamPlaybackDecision {
        let evidence = inspection.runtimeEvidence
        guard evidence.supportsDirectPlayback else {
            let reason: String
            if evidence.hasProtectedContent && !evidence.assetIsPlayable {
                reason = "Protected media failed the system playback check."
            } else if !evidence.assetIsPlayable {
                reason = "The asset failed the system playback check."
            } else {
                reason = "An enabled track failed the system playback check."
            }
            return OpenStreamPlaybackDecision(support: .unsupported, reasons: [reason])
        }
        return OpenStreamPlaybackDecision(support: .supported, reasons: [])
    }

    private static let rejectedInspection = AppleAssetInspection(
        formats: [],
        playable: false,
        readable: false,
        exportable: false,
        protectedContent: false
    )

    private static func streamSources(
        from sources: [AppleSource],
        preferredSourceID: AppleSource.ID?
    ) -> [AppleSource] {
        sources
            .filter { source in
                source.kind == .stremio
                    && source.isEnabled
                    && source.resources.contains { $0.caseInsensitiveCompare("stream") == .orderedSame }
            }
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.id == preferredSourceID
                let rhsPreferred = rhs.id == preferredSourceID
                return lhsPreferred && !rhsPreferred
            }
    }

    private func downloadPlan(
        for stream: AppleStremioHTTPPlaybackCandidate
    ) async throws -> AppleOfflineDownloadPlan {
        guard !stream.requestHeaders.isEmpty else {
            return AppleOfflineDownloadPlan(
                sourceURL: stream.sourceURL,
                requestHeaders: [:],
                protectedCapabilityToRevoke: nil
            )
        }
        let capability = try await protectedPlaybackURL(stream.sourceURL, stream.requestHeaders)
        return AppleOfflineDownloadPlan(
            sourceURL: capability,
            requestHeaders: [:],
            protectedCapabilityToRevoke: capability
        )
    }

    private func prepare(
        stream: AppleStremioHTTPPlaybackCandidate,
        gatewayConfig: AppleTranscodeGatewayConfig?,
        progress: (@Sendable (ApplePlaybackPhase) async -> Void)?
    ) async throws -> AppleResolvedStremioPlayback {
        var candidateCapability: URL?
        var usedGateway = false
        do {
            await progress?(.loading)
            let playbackURL = stream.requestHeaders.isEmpty
                ? stream.sourceURL
                : try await protectedPlaybackURL(stream.sourceURL, stream.requestHeaders)
            if !stream.requestHeaders.isEmpty { candidateCapability = playbackURL }

            let inspection: AppleAssetInspection
            do {
                inspection = try await inspectWithTimeout(playbackURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if stream.requiresGateway && gatewayConfig == nil && stream.requestHeaders.isEmpty {
                    throw CandidateAttemptError.provider(ApplePlaybackFailure.classify(error))
                }
                guard gatewayConfig != nil, stream.requestHeaders.isEmpty else {
                    throw CandidateAttemptError.provider(ApplePlaybackFailure.classify(error))
                }
                inspection = Self.rejectedInspection
            }
            try Task.checkCancellation()
            let gatewayRequest: AppleGatewayTranscodeRequest? = if !inspection.suitability.supportsDirectPlayback,
                                                                   let gatewayConfig,
                                                                   stream.requestHeaders.isEmpty {
                AppleGatewayTranscodeRequest(
                    config: gatewayConfig,
                    source: .remoteURL(stream.sourceURL),
                    maximumWidth: 3_840,
                    maximumHeight: 2_160
                )
            } else {
                nil
            }
            usedGateway = gatewayRequest != nil
            await progress?(.loading)
            let prepared = try await preparer(
                playbackURL,
                Self.decision(for: inspection),
                inspection,
                gatewayRequest
            )
            if let candidateCapability, prepared.url != playbackURL {
                await revokeProtectedPlaybackURL(candidateCapability)
            }
            return AppleResolvedStremioPlayback(stream: stream, preparedPlayback: prepared)
        } catch is CancellationError {
            if let candidateCapability { await revokeProtectedPlaybackURL(candidateCapability) }
            throw CancellationError()
        } catch let error as CandidateAttemptError {
            if let candidateCapability { await revokeProtectedPlaybackURL(candidateCapability) }
            throw error
        } catch ApplePlaybackPreparationError.externalDemuxRequired {
            if let candidateCapability { await revokeProtectedPlaybackURL(candidateCapability) }
            throw CandidateAttemptError.externalDemux
        } catch {
            if let candidateCapability { await revokeProtectedPlaybackURL(candidateCapability) }
            if usedGateway { throw CandidateAttemptError.gateway }
            let failure = ApplePlaybackFailure.classify(error)
            if failure.kind == .authentication || failure.kind == .network || failure.kind == .timedOut {
                throw CandidateAttemptError.provider(failure)
            }
            throw CandidateAttemptError.rejected
        }
    }

    private func resolveFirstPreparedCandidate(
        _ streams: [AppleStremioHTTPPlaybackCandidate],
        gatewayConfig: AppleTranscodeGatewayConfig?
    ) async throws -> (resolved: AppleResolvedStremioPlayback?, state: CandidateResolutionState) {
        let concurrencyLimit = min(6, streams.count)
        return try await withThrowingTaskGroup(of: CandidateResolutionOutcome.self) { group in
            var nextIndex = 0
            var state = CandidateResolutionState()

            for _ in 0 ..< concurrencyLimit {
                let stream = streams[nextIndex]
                nextIndex += 1
                group.addTask {
                    try await candidateOutcome(stream: stream, gatewayConfig: gatewayConfig)
                }
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .success(let resolved):
                    group.cancelAll()
                    return (resolved, state)
                case .failure(let error):
                    state.record(error)
                }

                if nextIndex < streams.count {
                    let stream = streams[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await candidateOutcome(stream: stream, gatewayConfig: gatewayConfig)
                    }
                }
            }

            return (nil, state)
        }
    }

    private func candidateOutcome(
        stream: AppleStremioHTTPPlaybackCandidate,
        gatewayConfig: AppleTranscodeGatewayConfig?
    ) async throws -> CandidateResolutionOutcome {
        do {
            return .success(try await prepare(
                stream: stream,
                gatewayConfig: gatewayConfig,
                progress: nil
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CandidateAttemptError {
            return .failure(error)
        } catch {
            return .failure(.provider(ApplePlaybackFailure.classify(error)))
        }
    }

    private static func streamingServerFailure(_ error: any Swift.Error) -> ApplePlaybackFailure {
        if let serviceError = error as? AppleStremioStreamingServerError {
            let kind: ApplePlaybackFailure.Kind = switch serviceError {
            case .invalidTorrent, .invalidResponse: .unavailable
            case .responseTooLarge, .requestFailed, .redirectRejected, .unreachable: .network
            }
            return ApplePlaybackFailure(kind: kind, message: serviceError.localizedDescription)
        }
        return ApplePlaybackFailure.classify(error)
    }

    private func inspectWithTimeout(_ url: URL) async throws -> AppleAssetInspection {
        try await withThrowingTaskGroup(of: AppleAssetInspection.self) { group in
            group.addTask { try await inspector(url) }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return result
        }
    }

    private static func priority(of error: AppleStremioPlaybackResolutionError) -> Int {
        switch error {
        case .providerFailure: 6
        case .gatewayUnavailable: 5
        case .externalDemuxRequired: 4
        case .noCompatibleHTTPStream: 3
        case .unsupportedOnly: 2
        case .noStreams: 1
        }
    }

    private enum CandidateAttemptError: Swift.Error, Sendable {
        case externalDemux
        case gateway
        case provider(ApplePlaybackFailure)
        case rejected
    }

    private enum CandidateResolutionOutcome: Sendable {
        case success(AppleResolvedStremioPlayback)
        case failure(CandidateAttemptError)
    }

    private struct CandidateResolutionState {
        var needsExternalDemux = false
        var gatewayFailed = false
        var lastProviderFailure: ApplePlaybackFailure?

        mutating func record(_ error: CandidateAttemptError) {
            switch error {
            case .externalDemux:
                needsExternalDemux = true
            case .gateway:
                gatewayFailed = true
            case .provider(let failure):
                lastProviderFailure = failure
            case .rejected:
                break
            }
        }
    }
}
