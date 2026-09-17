import Foundation

public enum OpenStreamDynamicRange: String, Codable, Sendable, CaseIterable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision
}

public enum OpenStreamDolbyVisionProfile: String, Codable, Sendable {
    case profile5 = "5"
    case profile7 = "7"
    case profile81 = "8.1"
    case profile82 = "8.2"
    case profile84 = "8.4"
    case unknown
}

public enum OpenStreamProjection: String, Codable, Sendable, CaseIterable {
    case flat
    case spatial
    case stereo180
    case mono180
    case stereo360
    case mono360
    case wideFOV
    case appleImmersive
    case unknown
}

public enum OpenStreamSupport: String, Codable, Sendable {
    case supported
    case runtimeCheck
    case unsupported
}

public struct OpenStreamFormat: Codable, Equatable, Sendable {
    public var dynamicRange: OpenStreamDynamicRange
    public var dolbyVisionProfile: OpenStreamDolbyVisionProfile?
    public var projection: OpenStreamProjection
    public var codec: String
    public var width: Int
    public var height: Int
    public var frameRate: Double

    public init(
        dynamicRange: OpenStreamDynamicRange,
        dolbyVisionProfile: OpenStreamDolbyVisionProfile? = nil,
        projection: OpenStreamProjection = .flat,
        codec: String,
        width: Int,
        height: Int,
        frameRate: Double
    ) {
        self.dynamicRange = dynamicRange
        self.dolbyVisionProfile = dolbyVisionProfile
        self.projection = projection
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

public struct OpenStreamCapabilityReport: Codable, Equatable, Sendable {
    public var platform: String
    public var hdrEligible: Bool
    public var dynamicRange: [OpenStreamDynamicRange: OpenStreamSupport]
    public var projections: [OpenStreamProjection: OpenStreamSupport]
    public var notes: [String]

    public init(
        platform: String,
        hdrEligible: Bool,
        dynamicRange: [OpenStreamDynamicRange: OpenStreamSupport],
        projections: [OpenStreamProjection: OpenStreamSupport],
        notes: [String] = []
    ) {
        self.platform = platform
        self.hdrEligible = hdrEligible
        self.dynamicRange = dynamicRange
        self.projections = projections
        self.notes = notes
    }
}

public struct OpenStreamPlaybackDecision: Equatable, Sendable {
    public var support: OpenStreamSupport
    public var reasons: [String]

    public init(support: OpenStreamSupport, reasons: [String]) {
        self.support = support
        self.reasons = reasons
    }
}

/// Decoder evidence gathered from the concrete `AVAsset` and its enabled
/// audio/video tracks. Container and codec labels are useful diagnostics, but
/// they are never sufficient proof that the current device can play an asset.
public struct OpenStreamRuntimePlaybackEvidence: Equatable, Sendable {
    public var assetIsPlayable: Bool
    public var assetIsReadable: Bool
    public var assetIsExportable: Bool
    public var hasProtectedContent: Bool
    public var enabledVideoTracksArePlayableAndDecodable: Bool
    public var enabledAudioTracksArePlayableAndDecodable: Bool

    public init(
        assetIsPlayable: Bool,
        assetIsReadable: Bool,
        assetIsExportable: Bool,
        hasProtectedContent: Bool,
        enabledVideoTracksArePlayableAndDecodable: Bool,
        enabledAudioTracksArePlayableAndDecodable: Bool
    ) {
        self.assetIsPlayable = assetIsPlayable
        self.assetIsReadable = assetIsReadable
        self.assetIsExportable = assetIsExportable
        self.hasProtectedContent = hasProtectedContent
        self.enabledVideoTracksArePlayableAndDecodable = enabledVideoTracksArePlayableAndDecodable
        self.enabledAudioTracksArePlayableAndDecodable = enabledAudioTracksArePlayableAndDecodable
    }

    public var supportsDirectPlayback: Bool {
        assetIsPlayable
            && enabledVideoTracksArePlayableAndDecodable
            && enabledAudioTracksArePlayableAndDecodable
    }
}

public enum OpenStreamCapabilityNegotiator {
    private static let maximumDimension = 32_768
    private static let maximumFrameRate = 480.0

    public static func evaluate(
        _ format: OpenStreamFormat,
        against report: OpenStreamCapabilityReport,
        runtime evidence: OpenStreamRuntimePlaybackEvidence? = nil
    ) -> OpenStreamPlaybackDecision {
        let normalizedCodec = format.codec.lowercased()
        guard normalizedCodec.utf8.count == 4,
              format.width > 0,
              format.height > 0,
              format.width <= maximumDimension,
              format.height <= maximumDimension,
              format.frameRate.isFinite,
              format.frameRate > 0,
              format.frameRate <= maximumFrameRate else {
            return OpenStreamPlaybackDecision(
                support: .unsupported,
                reasons: ["The codec, media geometry, or frame rate is invalid or outside the supported decision range."]
            )
        }

        let rangeSupport = report.dynamicRange[format.dynamicRange] ?? .unsupported
        let projectionSupport = report.projections[format.projection] ?? .unsupported
        if rangeSupport == .unsupported || projectionSupport == .unsupported {
            return OpenStreamPlaybackDecision(
                support: .unsupported,
                reasons: ["The current runtime rejected the requested dynamic range or projection."]
            )
        }

        if let evidence {
            guard evidence.supportsDirectPlayback else {
                let reason = if evidence.hasProtectedContent && !evidence.assetIsPlayable {
                    "The protected asset is not playable by the system media stack."
                } else if !evidence.assetIsPlayable {
                    "The asset is not playable by the system media stack."
                } else {
                    "An enabled audio or video track is not both playable and decodable."
                }
                return OpenStreamPlaybackDecision(support: .unsupported, reasons: [reason])
            }

            if projectionSupport == .runtimeCheck && format.projection != .flat {
                return OpenStreamPlaybackDecision(
                    support: .runtimeCheck,
                    reasons: ["Immersive presentation still requires an available AVKit experience."]
                )
            }
            return OpenStreamPlaybackDecision(support: .supported, reasons: [])
        }

        var reasons = ["Codec and container support require an asset and track decoder check."]
        if rangeSupport == .runtimeCheck { reasons.append("Dynamic range requires an asset and decoder check.") }
        if projectionSupport == .runtimeCheck { reasons.append("Immersive projection requires an AVKit experience check.") }
        if format.dynamicRange == .dolbyVision {
            reasons.append("Dolby Vision profile support is verified with the actual asset; HDR eligibility alone is insufficient.")
        }
        return OpenStreamPlaybackDecision(support: .runtimeCheck, reasons: reasons)
    }
}
