import AVFoundation
import Foundation
#if os(tvOS)
import AVKit
import UIKit
#endif

/// A source format and a display request are separate from evidence of HDMI output.
/// Public AVDisplayManager APIs do not report the active HDMI dynamic range.
struct ApplePlaybackDisplayTrace: Equatable, Sendable {
    var source: String = "unknown"
    var profile: String? = nil
    var renderer: String = "unknown"
    var preferredCriteria: String = "unavailable"
    var matchingEnabled: Bool? = nil
    var switchInProgress: Bool? = nil
    var currentMode: String = "unavailable"

    var line: String {
        "display source=\(source) dvProfile=\(profile ?? "unknown") renderer=\(renderer) "
        + "preferredDisplayCriteria=\(preferredCriteria) "
        + "isDisplayCriteriaMatchingEnabled=\(flag(matchingEnabled)) "
        + "displayModeSwitchInProgress=\(flag(switchInProgress)) "
        + "currentMode=\(currentMode) dynamicRangeRequested=\(flag(displayRequested)) dynamicRangeMatched=unverified"
    }

    private var displayRequested: Bool? {
        guard let matchingEnabled, preferredCriteria != "unavailable" else { return nil }
        return matchingEnabled && preferredCriteria != "none"
    }

    private func flag(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "unavailable"
    }

    static func hlsSource(videoRanges: [AVVideoRange]) -> Self {
        // A mixed master does not identify the selected variant. PQ is not proof of DV.
        guard let range = videoRanges.first, videoRanges.allSatisfy({ $0 == range }) else { return Self() }
        switch range {
        case .sdr: return Self(source: "SDR")
        case .hlg: return Self(source: "HLG")
        case .pq: return Self(source: "PQ")
        default: return Self()
        }
    }

    @MainActor
    static func source(for engine: any ApplePlaybackEngine) async -> Self {
        if let aether = engine as? AetherPlaybackEngine { return aether.displayTraceSource }
        guard let item = engine.avPlayer?.currentItem else { return Self() }
        let tracks = (try? await item.asset.loadTracks(withMediaType: .video)) ?? []
        // Playing HLS items can expose tracks even when the asset has none.
        for track in tracks + item.tracks.compactMap(\.assetTrack) {
            guard let descriptions = try? await track.load(.formatDescriptions),
                  let description = descriptions.first(where: { CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video }) else { continue }
            return source(description: description)
        }
        guard let asset = item.asset as? AVURLAsset else { return Self() }
        let variants = (try? await asset.load(.variants)) ?? []
        return hlsSource(videoRanges: variants.compactMap { $0.videoAttributes?.videoRange })
    }

    private static func source(description: CMFormatDescription) -> Self {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let format = AppleAssetInspector.inspect(description: description,
            width: Int(dimensions.width), height: Int(dimensions.height), frameRate: 0)
        let range: String
        switch format.dynamicRange {
        case .dolbyVision: range = "DV"
        case .hdr10: range = "HDR10"
        case .hdr10Plus: range = "HDR10+"
        case .hlg: range = "HLG"
        case .sdr: range = "SDR"
        }
        return Self(source: range, profile: format.dolbyVisionProfile?.rawValue)
    }

    @MainActor
    mutating func readDisplay() {
        #if os(tvOS)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        let manager = window.avDisplayManager
        // AVDisplayCriteria has no public getters for its format/rate. Preserve its
        // scrubbed diagnostic description rather than guessing from the source.
        preferredCriteria = manager.preferredDisplayCriteria.map {
            String(AppleDiagnosticsReport.redactLine(String(describing: $0))
                .replacingOccurrences(of: "\n", with: " ").prefix(240))
        } ?? "none"
        matchingEnabled = manager.isDisplayCriteriaMatchingEnabled
        switchInProgress = manager.isDisplayModeSwitchInProgress
        if let mode = window.screen.currentMode {
            currentMode = "\(Int(mode.size.width))x\(Int(mode.size.height));HDMI-range-unavailable"
        }
        #endif
    }
}
