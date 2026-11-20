import Foundation

/// A concrete URL produced by the selected route.
public struct ApplePreparedPlayback: Equatable, Sendable {
    public let route: ApplePlaybackRoute
    public let url: URL
    // Direct playback of an IPTV/live URL sometimes needs the provider's
    // User-Agent/Referer or the origin returns 403. Empty for everything
    // except direct live.
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

    public var errorDescription: String? {
        switch self {
        case .inspectionFailed(let message): "The system could not inspect this asset: \(message)"
        case .externalDemuxRequired: "This container requires an external demuxer."
        case .unavailable(let reasons): reasons.joined(separator: " ")
        }
    }
}

/// Executes route policy rather than merely describing it: direct assets are
/// returned unchanged and eligible local files are exported to a compatible
/// offline copy. Matroska is never handed to the native exporter.
public actor ApplePlaybackPreparer {
    /// Whether the system's own inspection says AVFoundation can play the asset as it is.
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

    private let exporter: AppleNativeMediaExporter

    public init(exporter: AppleNativeMediaExporter = .init()) {
        self.exporter = exporter
    }

    public func prepareLibraryMedia(
        sourceURL: URL,
        preferredEngine: ApplePlaybackEngineKind
    ) async throws -> ApplePreparedPlayback {
        try Task.checkCancellation()
        // The OpenStream engine inspects and demuxes files itself. AVAsset
        // inspection would reject formats such as Matroska before it can run.
        if preferredEngine == .openStream {
            return ApplePreparedPlayback(route: .direct(sourceURL), url: sourceURL)
        }
        let inspection = try await AppleAssetInspector.inspect(url: sourceURL)
        return try await prepare(sourceURL: sourceURL, decision: Self.decision(for: inspection), inspectedAsset: inspection)
    }

    public func prepare(
        sourceURL: URL,
        decision: OpenStreamPlaybackDecision,
        inspectedAsset: AppleAssetInspection? = nil
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

        let route = ApplePlaybackRoutePolicy.route(sourceURL: sourceURL, decision: decision, suitability: suitability)

        switch route {
        case .direct(let url):
            return ApplePreparedPlayback(route: route, url: url)
        case .nativeOfflineExport(let url):
            let compatibleURL = try await exporter.compatibleURL(for: url)
            return ApplePreparedPlayback(route: route, url: compatibleURL)
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
