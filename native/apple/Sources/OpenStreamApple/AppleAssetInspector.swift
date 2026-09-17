import AVFoundation
import CoreMedia
import Foundation

public struct AppleMetadataInspection: Equatable, Sendable {
    public let identifier: String
    public let value: String?
    public let languageTag: String?

    public init(identifier: String, value: String?, languageTag: String?) {
        self.identifier = identifier
        self.value = value
        self.languageTag = languageTag
    }
}

public struct AppleAudioFormatInspection: Equatable, Sendable {
    public let codec: String
    public let channelCount: Int
    public let sampleRate: Double
    public let channelLayoutTag: UInt32?

    public init(codec: String, channelCount: Int, sampleRate: Double, channelLayoutTag: UInt32?) {
        self.codec = codec
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayoutTag = channelLayoutTag
    }
}

public enum AppleMediaTrackKind: String, Equatable, Sendable {
    case audio
    case video
}

public struct AppleMediaTrackInspection: Equatable, Sendable {
    public let kind: AppleMediaTrackKind
    public let isEnabled: Bool
    public let isPlayable: Bool
    public let isDecodable: Bool
    public let codecs: [String]
    public let languageCode: String?
    public let extendedLanguageTag: String?
    public let estimatedDataRate: Double
    public let metadataFormats: [String]
    public let metadata: [AppleMetadataInspection]
    public let audioFormats: [AppleAudioFormatInspection]

    public init(
        kind: AppleMediaTrackKind,
        isEnabled: Bool,
        isPlayable: Bool,
        isDecodable: Bool,
        codecs: [String],
        languageCode: String?,
        extendedLanguageTag: String?,
        estimatedDataRate: Double,
        metadataFormats: [String],
        metadata: [AppleMetadataInspection],
        audioFormats: [AppleAudioFormatInspection] = []
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.isPlayable = isPlayable
        self.isDecodable = isDecodable
        self.codecs = codecs
        self.languageCode = languageCode
        self.extendedLanguageTag = extendedLanguageTag
        self.estimatedDataRate = estimatedDataRate
        self.metadataFormats = metadataFormats
        self.metadata = metadata
        self.audioFormats = audioFormats
    }

    public var supportsPlayback: Bool {
        !isEnabled || (isPlayable && isDecodable)
    }
}

public struct AppleContainerInspection: Equatable, Sendable {
    public let fileExtension: String
    public let duration: Double?
    public let metadataFormats: [String]
    public let metadata: [AppleMetadataInspection]

    public init(
        fileExtension: String,
        duration: Double?,
        metadataFormats: [String],
        metadata: [AppleMetadataInspection]
    ) {
        self.fileExtension = fileExtension
        self.duration = duration
        self.metadataFormats = metadataFormats
        self.metadata = metadata
    }

    public var requiresExternalDemux: Bool {
        fileExtension == "mkv" || fileExtension == "matroska"
    }
}

public struct AppleAssetInspection: Equatable, Sendable {
    public let formats: [OpenStreamFormat]
    public let playable: Bool
    public let readable: Bool
    public let exportable: Bool
    public let protectedContent: Bool
    public let videoTracks: [AppleMediaTrackInspection]
    public let audioTracks: [AppleMediaTrackInspection]
    public let container: AppleContainerInspection

    public init(
        formats: [OpenStreamFormat],
        playable: Bool,
        readable: Bool = false,
        exportable: Bool = false,
        protectedContent: Bool,
        videoTracks: [AppleMediaTrackInspection] = [],
        audioTracks: [AppleMediaTrackInspection] = [],
        container: AppleContainerInspection = .init(
            fileExtension: "",
            duration: nil,
            metadataFormats: [],
            metadata: []
        )
    ) {
        self.formats = formats
        self.playable = playable
        self.readable = readable
        self.exportable = exportable
        self.protectedContent = protectedContent
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.container = container
    }

    public var runtimeEvidence: OpenStreamRuntimePlaybackEvidence {
        OpenStreamRuntimePlaybackEvidence(
            assetIsPlayable: playable,
            assetIsReadable: readable,
            assetIsExportable: exportable,
            hasProtectedContent: protectedContent,
            enabledVideoTracksArePlayableAndDecodable: videoTracks.allSatisfy(\.supportsPlayback),
            enabledAudioTracksArePlayableAndDecodable: audioTracks.allSatisfy(\.supportsPlayback)
        )
    }

    public var suitability: AppleAssetSuitability {
        AppleAssetSuitability(
            isPlayable: playable,
            isReadable: readable,
            isExportable: exportable,
            isProtected: protectedContent,
            enabledVideoTracksArePlayableAndDecodable: runtimeEvidence.enabledVideoTracksArePlayableAndDecodable,
            enabledAudioTracksArePlayableAndDecodable: runtimeEvidence.enabledAudioTracksArePlayableAndDecodable
        )
    }
}

public enum AppleAssetInspector {
    public static func inspect(url: URL) async throws -> AppleAssetInspection {
        let asset = AVURLAsset(url: url)
        async let playable = asset.load(.isPlayable)
        async let readable = asset.load(.isReadable)
        async let exportable = asset.load(.isExportable)
        async let protectedContent = asset.load(.hasProtectedContent)
        async let duration = asset.load(.duration)
        async let metadataFormats = asset.load(.availableMetadataFormats)
        async let commonMetadata = asset.load(.commonMetadata)
        async let videoAssetTracks = asset.loadTracks(withMediaType: .video)
        async let audioAssetTracks = asset.loadTracks(withMediaType: .audio)

        let (rawVideoTracks, rawAudioTracks) = try await (videoAssetTracks, audioAssetTracks)
        var formats: [OpenStreamFormat] = []
        var videoTracks: [AppleMediaTrackInspection] = []
        var audioTracks: [AppleMediaTrackInspection] = []

        for track in rawVideoTracks {
            let inspection = try await inspectTrack(track, kind: .video)
            let dimensions = try await track.load(.naturalSize)
            let frameRate = Double(try await track.load(.nominalFrameRate))
            let safeWidth = safeDimension(Double(dimensions.width))
            let safeHeight = safeDimension(Double(dimensions.height))
            let safeRate = safeFrameRate(frameRate)
            for description in try await track.load(.formatDescriptions) {
                formats.append(inspect(
                    description: description,
                    width: safeWidth,
                    height: safeHeight,
                    frameRate: safeRate
                ))
            }
            videoTracks.append(inspection)
        }
        for track in rawAudioTracks {
            audioTracks.append(try await inspectTrack(track, kind: .audio))
        }

        let loadedDuration = try await duration
        let durationSeconds = loadedDuration.seconds
        let container = try await AppleContainerInspection(
            fileExtension: url.pathExtension.lowercased(),
            duration: durationSeconds.isFinite && durationSeconds >= 0 ? durationSeconds : nil,
            metadataFormats: metadataFormats.map(\.rawValue),
            metadata: inspectMetadata(commonMetadata)
        )
        return try await AppleAssetInspection(
            formats: formats,
            playable: playable,
            readable: readable,
            exportable: exportable,
            protectedContent: protectedContent,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            container: container
        )
    }

    public static func safeDimension(_ value: Double) -> Int {
        guard value.isFinite, value > 0, value <= Double(Int.max) else { return 0 }
        guard value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    public static func safeFrameRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0.0 }
        return value
    }

    public static func inspect(
        description: CMFormatDescription,
        width: Int,
        height: Int,
        frameRate: Double
    ) -> OpenStreamFormat {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
        let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let projectionKind = extensions[kCMFormatDescriptionExtension_ProjectionKind] as? String
        let hasLeftEye = (extensions[kCMFormatDescriptionExtension_HasLeftStereoEyeView] as? Bool) == true
        let hasRightEye = (extensions[kCMFormatDescriptionExtension_HasRightStereoEyeView] as? Bool) == true

        var dynamicRange: OpenStreamDynamicRange = .sdr
        var dolbyVisionProfile: OpenStreamDolbyVisionProfile?
        if codec == "dvh1" || codec == "dvhe" {
            dynamicRange = .dolbyVision
            dolbyVisionProfile = dolbyVisionConfiguration(in: extensions)?.profile(usingBaseTransferFunction: transfer) ?? .unknown
        } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            dynamicRange = .hdr10
        } else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            dynamicRange = .hlg
        }

        let projection = projection(
            kind: projectionKind,
            stereo: hasLeftEye && hasRightEye
        )
        let sanitizedWidth = max(0, width)
        let sanitizedHeight = max(0, height)
        let sanitizedFrameRate = (frameRate.isFinite && frameRate > 0) ? frameRate : 0.0
        return OpenStreamFormat(
            dynamicRange: dynamicRange,
            dolbyVisionProfile: dolbyVisionProfile,
            projection: projection,
            codec: codec,
            width: sanitizedWidth,
            height: sanitizedHeight,
            frameRate: sanitizedFrameRate
        )
    }

    private static func dolbyVisionConfiguration(in extensions: NSDictionary) -> DolbyVisionConfiguration? {
        guard let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary else { return nil }
        for key in ["dvcC", "dvvC"] {
            if let data = atoms[key] as? Data, let configuration = DolbyVisionConfiguration(record: data) {
                return configuration
            }
            if let records = atoms[key] as? [Data], let data = records.first, let configuration = DolbyVisionConfiguration(record: data) {
                return configuration
            }
        }
        return nil
    }

    private static func inspectTrack(
        _ track: AVAssetTrack,
        kind: AppleMediaTrackKind
    ) async throws -> AppleMediaTrackInspection {
        let enabled = try await track.load(.isEnabled)
        let playable = try await track.load(.isPlayable)
        let decodable = try await track.load(.isDecodable)
        let languageCode = try await track.load(.languageCode)
        let extendedLanguageTag = try await track.load(.extendedLanguageTag)
        let estimatedDataRate = try await track.load(.estimatedDataRate)
        let metadataFormats = try await track.load(.availableMetadataFormats)
        let commonMetadata = try await track.load(.commonMetadata)
        let descriptions = try await track.load(.formatDescriptions)
        let audioFormats = kind == .audio ? descriptions.compactMap(inspectAudio) : []
        return AppleMediaTrackInspection(
            kind: kind,
            isEnabled: enabled,
            isPlayable: playable,
            isDecodable: decodable,
            codecs: descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
            languageCode: languageCode,
            extendedLanguageTag: extendedLanguageTag,
            estimatedDataRate: Double(estimatedDataRate),
            metadataFormats: metadataFormats.map(\.rawValue),
            metadata: await inspectMetadata(commonMetadata),
            audioFormats: audioFormats
        )
    }

    private static func inspectAudio(_ description: CMFormatDescription) -> AppleAudioFormatInspection? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { return nil }
        let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        var layoutSize = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)?.pointee
        return AppleAudioFormatInspection(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            channelCount: Int(stream?.mChannelsPerFrame ?? 0),
            sampleRate: safeFrameRate(stream?.mSampleRate ?? 0),
            channelLayoutTag: layout?.mChannelLayoutTag
        )
    }

    private static func inspectMetadata(_ items: [AVMetadataItem]) async -> [AppleMetadataInspection] {
        var inspections: [AppleMetadataInspection] = []
        inspections.reserveCapacity(items.count)
        for item in items {
            let stringValue: String? = try? await item.load(.stringValue)
            let numberValue: NSNumber? = try? await item.load(.numberValue)
            inspections.append(AppleMetadataInspection(
                identifier: item.identifier?.rawValue ?? "unknown",
                value: stringValue ?? numberValue?.stringValue,
                languageTag: item.extendedLanguageTag
            ))
        }
        return inspections
    }

    static func projection(kind: String?, stereo: Bool) -> OpenStreamProjection {
        guard let kind else { return stereo ? .spatial : .flat }
        if kind == (kCMFormatDescriptionProjectionKind_HalfEquirectangular as String) {
            return stereo ? .stereo180 : .mono180
        }
        if kind == (kCMFormatDescriptionProjectionKind_Equirectangular as String) {
            return stereo ? .stereo360 : .mono360
        }
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            if kind == (kCMFormatDescriptionProjectionKind_AppleImmersiveVideo as String) { return .appleImmersive }
            if kind == (kCMFormatDescriptionProjectionKind_ParametricImmersive as String) { return .wideFOV }
        }
        return .unknown
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }
}
