import AVFoundation
import Foundation

public enum AppleCapabilityProbe {
    public static func current() -> OpenStreamCapabilityReport {
        let hdrEligible = AVPlayer.eligibleForHDRPlayback
        let hdrState: OpenStreamSupport = hdrEligible ? .runtimeCheck : .unsupported
        var projections = Dictionary(uniqueKeysWithValues: OpenStreamProjection.allCases.map { ($0, OpenStreamSupport.unsupported) })
        projections[.flat] = .supported

        #if os(visionOS)
        projections[.spatial] = .runtimeCheck
        projections[.stereo180] = .runtimeCheck
        projections[.mono180] = .runtimeCheck
        projections[.stereo360] = .runtimeCheck
        projections[.mono360] = .runtimeCheck
        projections[.wideFOV] = .runtimeCheck
        if #available(visionOS 26.0, *) { projections[.appleImmersive] = .runtimeCheck }
        let platform = "visionOS"
        #elseif os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS/iPadOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "Apple"
        #endif

        return OpenStreamCapabilityReport(
            platform: platform,
            hdrEligible: hdrEligible,
            dynamicRange: [
                .sdr: .supported,
                .hdr10: hdrState,
                .hdr10Plus: hdrState,
                .hlg: hdrState,
                .dolbyVision: hdrState,
            ],
            projections: projections,
            notes: [
                "AVPlayer.eligibleForHDRPlayback is a broad eligibility signal; each asset is inspected before route selection.",
                "Container and FourCC labels are diagnostic only; async AVAsset and enabled-track playback properties decide support.",
            ]
        )
    }
}
