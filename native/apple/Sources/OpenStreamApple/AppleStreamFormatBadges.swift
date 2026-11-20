import Foundation

/// A compact format badge on a title page: the picture's resolution, its
/// dynamic range, the channel layout, and whether the file is a remux.
///
/// Drawn as the same small grey outlined text badge the meta line already
/// uses (`AppleFormatBadge`), never a third-party wordmark and never a colour.
/// Dolby Vision reads as plain "HDR" and object audio has no badge: no
/// licensed format names on the badges (licence audit 2026-10-22).
/// Everything comes from data the app already holds: a stream's name,
/// description and `behaviorHints.filename`, a library file's name, or the
/// engine's probe of a local file. Nothing here asks the network.
public enum AppleStreamFormatBadge: Int, CaseIterable, Comparable, Sendable {
    // Stored as these numbers (`AppleMediaVersion.badgeValues`); 5 was Atmos.
    case uhd = 0
    case fullHD = 1
    case dolbyVision = 2
    case hdr10Plus = 3
    case hdr10 = 4
    case surround71 = 6
    case surround51 = 7
    case remux = 8

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .dolbyVision: "HDR"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR10"
        case .surround71: "7.1"
        case .surround51: "5.1"
        case .remux: "Remux"
        }
    }

    /// What VoiceOver reads.
    public var spokenName: String {
        switch self {
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .dolbyVision: "HDR"
        case .hdr10Plus: "HDR10 plus"
        case .hdr10: "HDR10"
        case .surround71: "7.1 surround"
        case .surround51: "5.1 surround"
        case .remux: "Remux"
        }
    }

    var isResolution: Bool { self == .uhd || self == .fullHD }

    /// The probed picture and sound of a local file, without engine types,
    /// so the mapping is testable.
    public struct ProbedFormat: Equatable, Sendable {
        public enum DynamicRange: Sendable { case sdr, hdr10, hdr10Plus, dolbyVision, hlg }
        public var width: Int
        public var height: Int
        public var dynamicRange: DynamicRange
        /// The default (or first) audio track's channel count; 0 when unknown.
        public var audioChannels: Int

        public init(width: Int, height: Int, dynamicRange: DynamicRange, audioChannels: Int) {
            self.width = width
            self.height = height
            self.dynamicRange = dynamicRange
            self.audioChannels = audioChannels
        }
    }

    /// Badges named in free text: a stream's name and description, a file
    /// name. One resolution, one dynamic range (Dolby Vision over HDR10+
    /// over HDR10), one channel layout (7.1 over 5.1), best first.
    public static func parse(_ text: String) -> [Self] {
        let value = text.lowercased()
        guard !value.isEmpty else { return [] }
        func has(_ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        var badges: [Self] = []
        let resolution = AppleReleaseName.resolution(value)
        if resolution >= 2160 { badges.append(.uhd) } else if resolution >= 1080 { badges.append(.fullHD) }
        if has(#"\b(?:dv|dovi|dolby[ ._-]?vision)\b"#) {
            badges.append(.dolbyVision)
        } else if has(#"\bhdr10(?:\+|p\b|plus\b)"#) {
            badges.append(.hdr10Plus)
        } else if has(#"\bhdr(?:10)?\b"#) {
            badges.append(.hdr10)
        }
        if has(#"(?<![0-9])(?<![0-9]\.)7[ .]1(?![0-9])"#) {
            badges.append(.surround71)
        } else if has(#"(?<![0-9])(?<![0-9]\.)5[ .]1(?![0-9])"#) {
            badges.append(.surround51)
        }
        if has(#"remux"#) { badges.append(.remux) }
        return badges
    }

    /// Badges the engine's probe proves.
    public static func badges(for probe: ProbedFormat) -> [Self] {
        var badges: [Self] = []
        if probe.width >= 3_800 || probe.height >= 2_100 {
            badges.append(.uhd)
        } else if probe.width >= 1_900 || probe.height >= 1_000 {
            badges.append(.fullHD)
        }
        switch probe.dynamicRange {
        case .dolbyVision: badges.append(.dolbyVision)
        case .hdr10Plus: badges.append(.hdr10Plus)
        case .hdr10: badges.append(.hdr10)
        case .sdr, .hlg: break
        }
        if probe.audioChannels >= 8 {
            badges.append(.surround71)
        } else if probe.audioChannels == 6 {
            badges.append(.surround51)
        }
        return badges
    }

    /// The probe wins for what it measures (picture, range, sound); the file
    /// name adds what a probe cannot see (Remux) and fills in the rest when
    /// there is no probe.
    public static func merged(probed: [Self]?, named: [Self]) -> [Self] {
        guard let probed else { return named.sorted() }
        var result = Set(probed)
        if named.contains(.remux) { result.insert(.remux) }
        // A probe that could not read the audio leaves the name's sound.
        if !probed.contains(where: { [.surround71, .surround51].contains($0) }) {
            for badge in named where [.surround71, .surround51].contains(badge) { result.insert(badge) }
        }
        return normalized(Array(result))
    }

    /// One of each kind, best first.
    static func normalized(_ badges: [Self]) -> [Self] {
        var set = Set(badges)
        if set.contains(.uhd) { set.remove(.fullHD) }
        if set.contains(.dolbyVision) { set.remove(.hdr10Plus); set.remove(.hdr10) }
        if set.contains(.hdr10Plus) { set.remove(.hdr10) }
        if set.contains(.surround71) { set.remove(.surround51) }
        return set.sorted()
    }

    /// The badges the meta line adds after the title's own catalog badges,
    /// leaving out any resolution or HDR the catalog already shows.
    public static func titles(_ badges: [Self], excludingCatalogBadges catalog: [String]) -> [String] {
        let shown = Set(catalog.map { $0.uppercased() })
        return badges.compactMap { badge -> String? in
            switch badge {
            case .uhd where shown.contains("4K"): return nil
            case .fullHD where shown.contains("4K") || shown.contains("HD"): return nil
            case .hdr10 where shown.contains("HDR") || shown.contains("HDR10+"): return nil
            case .dolbyVision where shown.contains("HDR"): return nil
            case .hdr10Plus where shown.contains("HDR10+"): return nil
            default: return badge.title
            }
        }
    }
}
