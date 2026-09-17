import Foundation

public enum AppleVideoCodec: String, Codable, Sendable {
    case avc
    case hevc
    case av1
    case unknown
}

public struct AppleOfflineDeviceProfile: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let codecs: Set<AppleVideoCodec>
    public let dynamicRanges: Set<OpenStreamDynamicRange>
    public let availableBytes: Int64

    public init(
        maximumWidth: Int,
        maximumHeight: Int,
        codecs: Set<AppleVideoCodec>,
        dynamicRanges: Set<OpenStreamDynamicRange>,
        availableBytes: Int64
    ) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.codecs = codecs
        self.dynamicRanges = dynamicRanges
        self.availableBytes = availableBytes
    }
}

public struct AppleOfflineVariant: Equatable, Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let bitrate: Int
    public let codec: AppleVideoCodec
    public let dynamicRange: OpenStreamDynamicRange
    public let estimatedBytes: Int64?

    public init(
        url: URL,
        width: Int,
        height: Int,
        bitrate: Int,
        codec: AppleVideoCodec,
        dynamicRange: OpenStreamDynamicRange,
        estimatedBytes: Int64? = nil
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.estimatedBytes = estimatedBytes
    }
}

public enum AppleOfflineQualityPolicy {
    public static func bestVariant(
        from variants: [AppleOfflineVariant],
        for device: AppleOfflineDeviceProfile
    ) -> AppleOfflineVariant? {
        variants
            .filter { variant in
                variant.width > 0 && variant.height > 0 &&
                    variant.width <= device.maximumWidth &&
                    variant.height <= device.maximumHeight &&
                    (device.codecs.contains(variant.codec) || variant.codec == .unknown) &&
                    device.dynamicRanges.contains(variant.dynamicRange) &&
                    (variant.estimatedBytes ?? 0) <= device.availableBytes
            }
            .max { lhs, rhs in
                score(lhs, device: device) < score(rhs, device: device)
            }
    }

    private static func score(_ variant: AppleOfflineVariant, device: AppleOfflineDeviceProfile) -> Int64 {
        let pixels = Int64(variant.width) * Int64(variant.height)
        let rangeBonus: Int64 = variant.dynamicRange == .dolbyVision ? 3_000_000_000 :
            (variant.dynamicRange == .sdr ? 0 : 2_000_000_000)
        let codecBonus: Int64 = variant.codec == .av1 ? 300_000_000 :
            (variant.codec == .hevc ? 200_000_000 : 100_000_000)
        return pixels * 1_000 + rangeBonus + codecBonus + Int64(variant.bitrate)
    }
}
