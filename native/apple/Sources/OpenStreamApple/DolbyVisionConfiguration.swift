import Foundation

public struct DolbyVisionConfiguration: Equatable, Sendable {
    public let profile: UInt8
    public let level: UInt8
    public let hasRPU: Bool
    public let hasEnhancementLayer: Bool
    public let hasBaseLayer: Bool
    public let baseLayerSignalCompatibilityID: UInt8

    public init?(record: Data) {
        guard record.count >= 5, record.count <= 256 else { return nil }
        let versionMajor = record[record.startIndex]
        guard versionMajor == 1 else { return nil }

        let profileAndLevel = record[record.index(record.startIndex, offsetBy: 2)]
        let levelAndFlags = record[record.index(record.startIndex, offsetBy: 3)]
        let parsedProfile = profileAndLevel >> 1
        let parsedLevel = ((profileAndLevel & 0x01) << 5) | (levelAndFlags >> 3)

        guard parsedProfile <= 31, parsedLevel <= 63 else { return nil }

        profile = parsedProfile
        level = parsedLevel
        hasRPU = (levelAndFlags & 0x04) != 0
        hasEnhancementLayer = (levelAndFlags & 0x02) != 0
        hasBaseLayer = (levelAndFlags & 0x01) != 0
        baseLayerSignalCompatibilityID = record[record.index(record.startIndex, offsetBy: 4)] >> 4
    }

    public var openStreamProfile: OpenStreamDolbyVisionProfile {
        switch profile {
        case 5: .profile5
        case 7: .profile7
        case 8: .unknown
        default: .unknown
        }
    }

    public func profile(usingBaseTransferFunction transferFunction: String?) -> OpenStreamDolbyVisionProfile {
        guard profile == 8 else { return openStreamProfile }
        switch baseLayerSignalCompatibilityID {
        case 1: return .profile81
        case 2: return .profile82
        case 4: return .profile84
        default: break
        }

        let normalized = transferFunction?.lowercased() ?? ""
        if normalized.contains("hlg") || normalized.contains("2100") { return .profile84 }
        if normalized.contains("2084") || normalized.contains("pq") { return .profile81 }
        return .unknown
    }
}
