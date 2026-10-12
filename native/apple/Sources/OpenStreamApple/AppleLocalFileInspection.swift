import Foundation
import AetherEngine

/// What the engine reads from a file on this device without playing it: the
/// format badges its probe proves, and for a disc image the titles on it.
struct AppleLocalFileInspection: Equatable, Sendable {
    var badges: [AppleStreamFormatBadge]
    var discTitles: [AppleDiscTitle]

    /// Blocking file reads; call off the main actor. A file the engine cannot
    /// read gives its name's badges and no titles.
    static func inspect(url: URL, isDisc: Bool) -> Self {
        let named = AppleStreamFormatBadge.parse(url.lastPathComponent)
        var titles: [AppleDiscTitle] = []
        if isDisc {
            let inspection = AetherEngine.inspectDisc(url: url)
            titles = inspection.titles.map {
                AppleDiscTitle(id: $0.id, durationSeconds: $0.durationSeconds, chapterCount: $0.chapterStartsSeconds.count)
            }
        }
        let probed = (try? AetherEngine.probe(url: url)).map { AppleStreamFormatBadge.badges(for: Self.format(of: $0)) }
        return Self(badges: AppleStreamFormatBadge.merged(probed: probed, named: named), discTitles: titles)
    }

    static func format(of probe: SourceProbe) -> AppleStreamFormatBadge.ProbedFormat {
        let audio = probe.audioTracks.first(where: \.isDefault) ?? probe.audioTracks.first
        let range: AppleStreamFormatBadge.ProbedFormat.DynamicRange = switch probe.videoFormat {
        case .sdr: .sdr
        case .hdr10: .hdr10
        case .hdr10Plus: .hdr10Plus
        case .dolbyVision: .dolbyVision
        case .hlg: .hlg
        }
        return .init(width: Int(probe.videoWidth), height: Int(probe.videoHeight),
                     dynamicRange: probe.isDolbyVision ? .dolbyVision : range,
                     audioChannels: audio?.channels ?? 0, isAtmos: audio?.isAtmos ?? false)
    }
}
