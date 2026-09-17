import Foundation

public struct AppleGatewayTranscodeRequest: Equatable, Sendable {
    public let config: AppleTranscodeGatewayConfig
    public let source: AppleGatewayTranscodeSource
    public let maximumWidth: Int
    public let maximumHeight: Int

    public init(
        config: AppleTranscodeGatewayConfig,
        source: AppleGatewayTranscodeSource,
        maximumWidth: Int,
        maximumHeight: Int
    ) {
        self.config = config
        self.source = source
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }

    public init(
        config: AppleTranscodeGatewayConfig,
        smbURI: String,
        maximumWidth: Int,
        maximumHeight: Int
    ) {
        self.init(
            config: config,
            source: .smbURI(smbURI),
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight
        )
    }
}

/// A concrete URL produced by the selected route. Gateway playback URLs are
/// narrow bearer capabilities, so stock AVPlayer can consume them without
/// global session headers or undocumented asset options.
public struct ApplePreparedPlayback: Equatable, Sendable {
    public let route: ApplePlaybackRoute
    public let url: URL
    // Direct playback of an IPTV/live URL sometimes needs the provider's
    // User-Agent/Referer or the origin returns 403; gateway URLs are bearer
    // capabilities and carry none. Empty for everything except direct live.
    public let requestHeaders: [String: String]

    public init(route: ApplePlaybackRoute, url: URL, requestHeaders: [String: String] = [:]) {
        self.route = route
        self.url = url
        self.requestHeaders = requestHeaders
    }
}

public enum ApplePlaybackPreparationError: Swift.Error, LocalizedError, Equatable, Sendable {
    case inspectionFailed(String)
    case externalDemuxRequired
    case unavailable([String])
    case gatewayRequestRequired
    case gatewayDisabled
    case gatewayUnavailable
    case invalidGatewayDimensions
    case gatewaySourceMismatch

    public var errorDescription: String? {
        switch self {
        case .inspectionFailed(let message): "The system could not inspect this asset: \(message)"
        case .externalDemuxRequired: "This container requires an external demuxer."
        case .unavailable(let reasons): reasons.joined(separator: " ")
        case .gatewayRequestRequired: "This source requires an explicit local gateway media mapping."
        case .gatewayDisabled: "The configured local gateway is disabled."
        case .gatewayUnavailable: "The local gateway cannot transcode media on this machine."
        case .invalidGatewayDimensions: "The gateway playback dimensions are invalid."
        case .gatewaySourceMismatch: "The gateway source does not match the asset inspected for playback."
        }
    }
}

/// Executes route policy rather than merely describing it: direct assets are
/// returned unchanged, eligible local files are exported to a compatible
/// offline copy, and an explicit remote URL or SMB mapping creates a real
/// gateway session. Matroska is never handed to the native exporter.
public actor ApplePlaybackPreparer {
    private let exporter: AppleNativeMediaExporter
    private let gatewayClient: AppleTranscodeGatewayClient

    public init(
        exporter: AppleNativeMediaExporter = .init(),
        gatewayClient: AppleTranscodeGatewayClient = .init()
    ) {
        self.exporter = exporter
        self.gatewayClient = gatewayClient
    }

    public func prepareLibraryMedia(
        sourceURL: URL,
        preferredEngine: ApplePlaybackEngineKind,
        gatewayRequest: AppleGatewayTranscodeRequest? = nil
    ) async throws -> ApplePreparedPlayback {
        try Task.checkCancellation()
        // The OpenStream engine inspects and demuxes files itself. AVAsset
        // inspection would reject formats such as Matroska before it can run.
        if preferredEngine == .openStream {
            return ApplePreparedPlayback(route: .direct(sourceURL), url: sourceURL)
        }
        let inspection: AppleAssetInspection
        do {
            inspection = try await AppleAssetInspector.inspect(url: sourceURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard gatewayRequest != nil else { throw error }
            inspection = AppleAssetInspection(
                formats: [], playable: false, readable: false, exportable: false, protectedContent: false,
                container: .init(fileExtension: sourceURL.pathExtension, duration: nil, metadataFormats: [], metadata: [])
            )
        }
        return try await prepare(
            sourceURL: sourceURL,
            decision: AppleStremioPlaybackResolver.decision(for: inspection),
            inspectedAsset: inspection,
            gatewayRequest: gatewayRequest
        )
    }

    public func prepare(
        sourceURL: URL,
        decision: OpenStreamPlaybackDecision,
        inspectedAsset: AppleAssetInspection? = nil,
        gatewayRequest: AppleGatewayTranscodeRequest? = nil
    ) async throws -> ApplePreparedPlayback {
        let isMatroska = Self.isMatroska(sourceURL)
        let suitability: AppleAssetSuitability
        if isMatroska {
            suitability = AppleAssetSuitability(
                isPlayable: false,
                isReadable: false,
                isExportable: false,
                isProtected: false
            )
        } else if let inspectedAsset {
            suitability = inspectedAsset.suitability
        } else {
            do {
                suitability = try await AppleAssetInspector.inspect(url: sourceURL).suitability
            } catch {
                throw ApplePlaybackPreparationError.inspectionFailed(error.localizedDescription)
            }
        }

        let gatewayConfigured = gatewayRequest?.config.isEnabled == true
        let route = ApplePlaybackRoutePolicy.route(
            sourceURL: sourceURL,
            decision: decision,
            suitability: suitability,
            gatewayConfigured: gatewayConfigured
        )

        switch route {
        case .direct(let url):
            return ApplePreparedPlayback(route: route, url: url)
        case .nativeOfflineExport(let url):
            let compatibleURL = try await exporter.compatibleURL(for: url)
            return ApplePreparedPlayback(route: route, url: compatibleURL)
        case .gatewayTranscode:
            guard let gatewayRequest else {
                throw ApplePlaybackPreparationError.gatewayRequestRequired
            }
            guard gatewayRequest.config.isEnabled else {
                throw ApplePlaybackPreparationError.gatewayDisabled
            }
            guard (1 ... 32_768).contains(gatewayRequest.maximumWidth),
                  (1 ... 32_768).contains(gatewayRequest.maximumHeight) else {
                throw ApplePlaybackPreparationError.invalidGatewayDimensions
            }
            if case .remoteURL(let remoteURL) = gatewayRequest.source,
               remoteURL != sourceURL {
                throw ApplePlaybackPreparationError.gatewaySourceMismatch
            }
            let capabilities = try await gatewayClient.capabilities(config: gatewayRequest.config)
            guard capabilities.available else {
                throw ApplePlaybackPreparationError.gatewayUnavailable
            }
            let session = try await gatewayClient.startSession(
                config: gatewayRequest.config,
                source: gatewayRequest.source,
                maximumWidth: gatewayRequest.maximumWidth,
                maximumHeight: gatewayRequest.maximumHeight
            )
            return ApplePreparedPlayback(
                route: route,
                url: session.url
            )
        case .requiresExternalDemux:
            throw ApplePlaybackPreparationError.externalDemuxRequired
        case .unavailable(let reasons):
            throw ApplePlaybackPreparationError.unavailable(reasons)
        }
    }

    private static func isMatroska(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "mkv" || fileExtension == "matroska"
    }
}
