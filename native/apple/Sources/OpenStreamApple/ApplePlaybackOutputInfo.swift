import Foundation

/// Only populated with the renderer's reported range. Unknown is distinct
/// from SDR; a title, filename or container tag is never output evidence.
public struct ApplePlaybackOutputInfo: Equatable, Sendable {
    public enum DynamicRange: String, Sendable {
        case dolbyVision = "Dolby Vision"
        case hdr10 = "HDR10"
        case hdr10Plus = "HDR10+"
        case hlg = "HLG"
        case sdr = "SDR"
    }
    public let dynamicRange: DynamicRange?
    public let channels: Int

    public init(dynamicRange: DynamicRange?, channels: Int = 0) {
        self.dynamicRange = dynamicRange
        self.channels = channels
    }

    public var line: String? {
        var parts = dynamicRange.map { [$0.rawValue] } ?? []
        switch channels {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case 6: parts.append("5.1")
        case 8: parts.append("7.1")
        case 3...: parts.append("\(channels) channels")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
