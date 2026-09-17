import AVFoundation
import Foundation

public enum ApplePlaybackRoute: Equatable, Sendable {
    case direct(URL)
    case nativeOfflineExport(URL)
    case gatewayTranscode(URL)
    case requiresExternalDemux(URL)
    case unavailable([String])
}

public struct AppleAssetSuitability: Equatable, Sendable {
    public var isPlayable: Bool
    public var isReadable: Bool
    public var isExportable: Bool
    public var isProtected: Bool
    public var enabledVideoTracksArePlayableAndDecodable: Bool
    public var enabledAudioTracksArePlayableAndDecodable: Bool

    public init(
        isPlayable: Bool,
        isReadable: Bool,
        isExportable: Bool,
        isProtected: Bool,
        enabledVideoTracksArePlayableAndDecodable: Bool = true,
        enabledAudioTracksArePlayableAndDecodable: Bool = true
    ) {
        self.isPlayable = isPlayable
        self.isReadable = isReadable
        self.isExportable = isExportable
        self.isProtected = isProtected
        self.enabledVideoTracksArePlayableAndDecodable = enabledVideoTracksArePlayableAndDecodable
        self.enabledAudioTracksArePlayableAndDecodable = enabledAudioTracksArePlayableAndDecodable
    }

    public var supportsDirectPlayback: Bool {
        isPlayable
            && enabledVideoTracksArePlayableAndDecodable
            && enabledAudioTracksArePlayableAndDecodable
    }

    public var supportsNativeOfflineExport: Bool {
        isReadable
            && isExportable
            && !isProtected
            && enabledVideoTracksArePlayableAndDecodable
            && enabledAudioTracksArePlayableAndDecodable
    }
}

public enum ApplePlaybackRoutePolicy {
    public static func route(
        sourceURL: URL,
        decision: OpenStreamPlaybackDecision,
        suitability: AppleAssetSuitability? = nil,
        gatewayConfigured: Bool = false
    ) -> ApplePlaybackRoute {
        if let suitability, suitability.isProtected {
            return suitability.supportsDirectPlayback
                ? .direct(sourceURL)
                : .unavailable(unavailableReasons(decision, fallback: "Protected media is not playable on this device."))
        }
        // The engine demuxes Matroska and MPEG-TS in-app; never route these to
        // the gateway or the native exporter.
        if isMatroska(sourceURL) || isMPEGTransportStream(sourceURL) {
            return .direct(sourceURL)
        }
        if suitability?.supportsDirectPlayback == true { return .direct(sourceURL) }

        if suitability?.isReadable == false {
            return gatewayConfigured ? .gatewayTranscode(sourceURL) : .requiresExternalDemux(sourceURL)
        }

        if let suitability {
            if sourceURL.isFileURL && suitability.supportsNativeOfflineExport {
                return .nativeOfflineExport(sourceURL)
            }
            if gatewayConfigured, decision.support == .unsupported { return .gatewayTranscode(sourceURL) }
            return .unavailable(unavailableReasons(decision, fallback: "The asset failed the system playback checks."))
        }

        return switch decision.support {
        case .supported, .runtimeCheck:
            .direct(sourceURL)
        case .unsupported where gatewayConfigured:
            .gatewayTranscode(sourceURL)
        case .unsupported:
            .unavailable(unavailableReasons(decision, fallback: "The asset requires runtime inspection."))
        }
    }

    public static func inspectAndRoute(
        sourceURL: URL,
        decision: OpenStreamPlaybackDecision,
        gatewayConfigured: Bool = false
    ) async throws -> ApplePlaybackRoute {
        let inspection = try await AppleAssetInspector.inspect(url: sourceURL)
        return route(
            sourceURL: sourceURL,
            decision: decision,
            suitability: inspection.suitability,
            gatewayConfigured: gatewayConfigured
        )
    }

    private static func isMatroska(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "mkv" || fileExtension == "matroska"
    }

    private static func isMPEGTransportStream(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "ts" || fileExtension == "m2ts" || fileExtension == "mts"
    }

    private static func unavailableReasons(
        _ decision: OpenStreamPlaybackDecision,
        fallback: String
    ) -> [String] {
        decision.reasons.isEmpty ? [fallback] : decision.reasons
    }
}

public enum AppleLocalTranscodeError: Swift.Error, LocalizedError, Sendable {
    case sourceMustBeLocal
    case protectedContent
    case assetNotReadable
    case assetNotExportable
    case enabledTrackNotDecodable
    case externalDemuxRequired
    case noCompatibleExporter
    case unsupportedOutput
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMustBeLocal: "Local transcoding requires a file stored on this device."
        case .protectedContent: "Protected media cannot be converted into an offline copy."
        case .assetNotReadable: "The system media stack cannot read this file."
        case .assetNotExportable: "The system media stack cannot export this file."
        case .enabledTrackNotDecodable: "An enabled audio or video track cannot be decoded by the system media stack."
        case .externalDemuxRequired: "This container requires an external demuxer; native offline export was not attempted."
        case .noCompatibleExporter: "This file cannot be converted by the system media stack."
        case .unsupportedOutput: "No compatible local output format is available."
        case .exportFailed(let message): "Local conversion failed: \(message)"
        }
    }
}

/// Produces a cached compatible file only for local, unprotected assets that
/// AVFoundation has already proven readable and exportable. This is not a
/// general-purpose MKV demuxer or a live transcoder.
public actor AppleNativeMediaExporter {
    private let outputDirectory: URL
    private let fileManager: FileManager

    public init(
        outputDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.outputDirectory = outputDirectory ?? fileManager.temporaryDirectory
            .appending(path: "OpenStreamTranscodes", directoryHint: .isDirectory)
    }

    public func compatibleURL(for sourceURL: URL) async throws -> URL {
        guard sourceURL.isFileURL else { throw AppleLocalTranscodeError.sourceMustBeLocal }
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard sourceExtension != "mkv", sourceExtension != "matroska" else {
            throw AppleLocalTranscodeError.externalDemuxRequired
        }

        let inspection = try await AppleAssetInspector.inspect(url: sourceURL)
        guard !inspection.protectedContent else { throw AppleLocalTranscodeError.protectedContent }
        guard inspection.readable else { throw AppleLocalTranscodeError.assetNotReadable }
        guard inspection.exportable else { throw AppleLocalTranscodeError.assetNotExportable }
        guard inspection.videoTracks.allSatisfy(\.supportsPlayback),
              inspection.audioTracks.allSatisfy(\.supportsPlayback) else {
            throw AppleLocalTranscodeError.enabledTrackNotDecodable
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Read fresh filesystem metadata; URL resource values can retain the
        // previous size/date when the same URL value survives replacement.
        let sourceValues = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceValues[.size] as? NSNumber)?.int64Value ?? 0
        let sourceModified = (sourceValues[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let sourceFileID = (sourceValues[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let sourceIdentity = "\(sourceURL.standardizedFileURL.absoluteString)|\(sourceSize)|\(sourceModified)|\(sourceFileID)"
        let destination = outputDirectory
            .appending(path: ApplePlaybackIdentity.digest(for: sourceIdentity))
            .appendingPathExtension("mp4")
        if fileManager.fileExists(atPath: destination.path) {
            if let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value > 0,
               let cachedInspection = try? await AppleAssetInspector.inspect(url: destination),
               cachedInspection.suitability.supportsDirectPlayback {
                return destination
            }
            try? fileManager.removeItem(at: destination)
        }

        let temporary = outputDirectory
            .appending(path: "\(destination.deletingPathExtension().lastPathComponent).partial-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppleLocalTranscodeError.noCompatibleExporter
        }
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw AppleLocalTranscodeError.unsupportedOutput
        }

        do {
            try await exporter.export(to: temporary, as: .mp4)
            try Task.checkCancellation()
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                // Another exporter can publish the same source version while
                // this actor is suspended in AVFoundation. Reuse only a valid
                // complete file and discard our private temporary output.
                guard fileManager.fileExists(atPath: destination.path),
                      let completed = try? await AppleAssetInspector.inspect(url: destination),
                      completed.suitability.supportsDirectPlayback else { throw error }
                try? fileManager.removeItem(at: temporary)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AppleLocalTranscodeError.exportFailed(error.localizedDescription)
        }
    }

    public func removeCachedFiles() throws {
        guard fileManager.fileExists(atPath: outputDirectory.path) else { return }
        try fileManager.removeItem(at: outputDirectory)
    }

}

@available(*, deprecated, renamed: "AppleNativeMediaExporter")
public typealias AppleLocalTranscoder = AppleNativeMediaExporter
