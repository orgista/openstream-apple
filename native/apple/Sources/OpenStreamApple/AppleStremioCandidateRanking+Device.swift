import Foundation

/// A resolution the quality picker offers. The picker names the picture,
/// never the file: no codec, container, HDR or Dolby Vision words, no source
/// names (owner 2026-09-24: "there should be 1 source per resolution and
/// Automatic").
public enum AppleStreamQualityTier: Int, CaseIterable, Comparable, Sendable {
    case sd = 480
    case hd = 720
    case fullHD = 1080
    case uhd = 2160

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .sd: "SD"
        case .hd: "720p"
        case .fullHD: "1080p"
        case .uhd: "4K"
        }
    }

    /// 1440p sits with 1080p and 8K with 4K; an unstated resolution has no tier.
    public init?(resolution: Int) {
        switch resolution {
        case 2160...: self = .uhd
        case 1080..<2160: self = .fullHD
        case 720..<1080: self = .hd
        case 1..<720: self = .sd
        default: return nil
        }
    }
}

/// What the viewer asked the picker for.
public enum AppleStreamQualityChoice: Hashable, Sendable {
    case automatic
    case tier(AppleStreamQualityTier)
}

/// What this device can present, for choosing among candidates.
public struct AppleStreamDeviceCapabilities: Equatable, Sendable {
    public var supportsHDR: Bool
    public var supportsDolbyVision: Bool
    /// The highest tier Automatic reaches for; the picker still offers more.
    public var automaticTierCap: AppleStreamQualityTier

    public init(supportsHDR: Bool, supportsDolbyVision: Bool, automaticTierCap: AppleStreamQualityTier = .uhd) {
        self.supportsHDR = supportsHDR
        self.supportsDolbyVision = supportsDolbyVision
        self.automaticTierCap = automaticTierCap
    }
}

extension AppleStremioCandidateRanking {
    /// What a candidate's name says about how this device can play it.
    public struct PlaybackTraits: Equatable, Sendable {
        public enum Container: Sendable { case mp4, matroska, transportStream, other, unknown }
        public enum VideoCodec: Sendable { case h264, hevc, av1, other, unknown }
        public enum AudioCodec: Sendable { case avPlayerSafe, needsTranscode, unknown }
        public enum DynamicRange: Sendable, Equatable { case sdr, hdr, dolbyVision(hasHDRFallback: Bool) }

        public let container: Container
        public let video: VideoCodec
        public let audio: AudioCodec
        public let dynamicRange: DynamicRange
        public let tier: AppleStreamQualityTier?
        /// The add-on marked it not web-ready: only the engine's gateway plays it.
        public let requiresGateway: Bool
    }

    /// How directly this device plays a candidate, best first.
    ///
    /// 0 direct play: an MP4/MOV of H.264 or HEVC with AAC, AC-3 or E-AC-3 —
    ///   AVPlayer opens the file itself.
    /// 1 remux: Matroska, TS or an unnamed file of the same codecs — the
    ///   engine repackages it for AVPlayer on the fly (the loopback route).
    /// 2 other: audio AVPlayer cannot decode (DTS, TrueHD, FLAC, Opus) or a
    ///   picture it cannot (AV1, VP9, MPEG-2, Xvid) — transcoded or decoded
    ///   in software.
    public enum PlaybackClass: Int, Comparable, Sendable {
        case directPlay, remux, other
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static func traits(of candidate: AppleStremioHTTPPlaybackCandidate) -> PlaybackTraits {
        let name = (candidate.filename ?? candidate.sourceURL.lastPathComponent).lowercased()
        let text = [candidate.qualityDescription ?? "", candidate.title, candidate.filename ?? "",
                    candidate.sourceURL.lastPathComponent].joined(separator: " ").lowercased()
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        let ext = name.contains(".") ? String(name[name.index(after: name.lastIndex(of: ".")!)...]) : ""
        let container: PlaybackTraits.Container = switch ext {
        case "mp4", "m4v", "mov": .mp4
        case "mkv", "webm": .matroska
        case "ts", "m2ts", "mts": .transportStream
        case "avi", "wmv", "flv", "mpg", "mpeg": .other
        default: has(#"\bmkv\b"#) ? .matroska
            : has(#"\bmp4\b"#) || Self.urlNamesMPEG4(candidate.sourceURL) ? .mp4 : .unknown
        }
        let video: PlaybackTraits.VideoCodec =
            if has(#"\b(?:x265|h\.?265|hevc)\b"#) { .hevc }
            else if has(#"\b(?:x264|h\.?264|avc)\b"#) { .h264 }
            else if has(#"\bav1\b"#) { .av1 }
            else if has(#"\b(?:vp9|xvid|divx|mpeg-?2|vc-?1)\b"#) { .other }
            else { .unknown }
        let audio: PlaybackTraits.AudioCodec =
            if has(#"\b(?:truehd|dts(?:-?hd|-?x|-?ma)?|flac|opus|lpcm|pcm)\b"#) { .needsTranscode }
            else if has(#"\b(?:aac|ac-?3|e-?ac-?3|eac3|ddp?\+?(?:[257]\.1)?|dd\+|atmos)\b"#) { .avPlayerSafe }
            else { .unknown }
        let dolbyVision = has(#"\b(?:dv|dovi|dolby[ ._-]?vision)\b"#)
        let hdr = has(#"\b(?:hdr(?:10\+?)?|hlg)\b"#)
        let range: PlaybackTraits.DynamicRange =
            dolbyVision ? .dolbyVision(hasHDRFallback: hdr) : hdr ? .hdr : .sdr
        let tier = AppleStreamQualityTier(resolution: resolution(
            [candidate.qualityDescription ?? candidate.title, candidate.filename ?? "",
             candidate.sourceURL.lastPathComponent].joined(separator: " ")))
        return PlaybackTraits(container: container, video: video, audio: audio, dynamicRange: range,
                              tier: tier, requiresGateway: candidate.requiresGateway)
    }

    public static func playbackClass(_ traits: PlaybackTraits) -> PlaybackClass {
        if traits.audio == .needsTranscode { return .other }
        switch traits.video {
        case .av1, .other: return .other
        case .h264, .hevc, .unknown: break
        }
        switch traits.container {
        case .mp4 where !traits.requiresGateway: return .directPlay
        case .other: return .other
        default: return .remux
        }
    }

    /// An MP4/M4V named anywhere in the URL's path (a debrid link often ends
    /// in an opaque id with the file name one segment earlier).
    static func urlNamesMPEG4(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains(".mp4") || path.contains(".m4v")
    }

    /// The order under the DEBUG Native override (`stockPlayerOnly`): a
    /// release that says it is MPEG-4 first, then
    /// one whose container is unknown (it may be anything — SNL S51E7's first
    /// three unknown names all failed "no video track"), then the rest.
    static func stockPlayerScore(_ traits: PlaybackTraits) -> Int {
        guard stockPlayerPlays(traits) else { return 0 }
        return traits.container == .mp4 ? 2 : 1
    }

    /// Whether the AVPlayer-only engine opens this release: an MPEG-4 file or
    /// a name that says nothing about its container (HLS, bare URLs), and
    /// not one the add-on marked as needing the gateway.
    public static func stockPlayerPlays(_ traits: PlaybackTraits) -> Bool {
        guard !traits.requiresGateway else { return false }
        switch traits.container {
        case .mp4, .unknown: return true
        case .matroska, .transportStream, .other: return false
        }
    }

    /// A Dolby Vision stream with no HDR10 base layer (profile 5) plays in
    /// the wrong colours on a display without Dolby Vision, so it does not
    /// count as playable there; one with a base layer plays as HDR10.
    public static func isPlayable(_ traits: PlaybackTraits, on device: AppleStreamDeviceCapabilities) -> Bool {
        if case .dolbyVision(false) = traits.dynamicRange { return device.supportsDolbyVision }
        return true
    }

    /// Higher is better: Dolby Vision, then HDR, only where the display
    /// shows them; elsewhere the SDR release, which needs no tone mapping.
    static func dynamicRangeScore(_ range: PlaybackTraits.DynamicRange, on device: AppleStreamDeviceCapabilities) -> Int {
        switch range {
        case .dolbyVision:
            if device.supportsDolbyVision { return 3 }
            return device.supportsHDR ? 2 : 1
        case .hdr: return device.supportsHDR ? 2 : 1
        case .sdr: return device.supportsHDR ? 1 : 3
        }
    }

    /// The tiers the picker offers: every resolution with a candidate this
    /// device can play, best first. SD only when nothing better exists.
    public static func qualityTiers(
        _ candidates: [AppleStremioHTTPPlaybackCandidate],
        device: AppleStreamDeviceCapabilities
    ) -> [AppleStreamQualityTier] {
        var tiers = Set<AppleStreamQualityTier>()
        for candidate in candidates {
            let traits = traits(of: candidate)
            if let tier = traits.tier, isPlayable(traits, on: device) { tiers.insert(tier) }
        }
        if tiers.count > 1 { tiers.remove(.sd) }
        return tiers.sorted(by: >)
    }

    /// Everything to try, in order, for a picker choice on this device.
    ///
    /// `candidates` arrive in `rankForAutomaticPlayback` order, so a release
    /// naming the wrong title or episode is already at the back; that
    /// demotion holds here too. Then:
    /// - the chosen tier (Automatic: the best tier up to the device's cap,
    ///   then lower tiers, unnamed resolutions, and last the tiers above the
    ///   cap), ranked within itself by `PlaybackClass`, then by dynamic range
    ///   for this display, then in the order they arrived (size, provider);
    /// - for a named tier, the other tiers after it, nearest first, so a
    ///   failure falls to the closest picture rather than to anything;
    /// - candidates this device cannot present properly, last of all.
    ///
    /// Among the candidates this device can play, those from a service in
    /// `unhealthyServices` (`AppleStreamServiceHealth`) go after every other
    /// service's, so a service that is down is still tried, but only once
    /// nothing else is left. Within a tier, `preferredService` (the service
    /// the previous episode played from) goes first.
    public static func playbackOrder(
        _ candidates: [AppleStremioHTTPPlaybackCandidate],
        choice: AppleStreamQualityChoice,
        device: AppleStreamDeviceCapabilities,
        episode: (season: Int, episode: Int)? = nil,
        title: String? = nil,
        year: Int? = nil,
        unhealthyServices: Set<String> = [],
        preferredService: String? = nil,
        stockPlayerOnly: Bool = false
    ) -> [AppleStremioHTTPPlaybackCandidate] {
        let mismatched = titleMismatches(candidates, title: title, year: year, season: episode?.season)
        let tierRank: (AppleStreamQualityTier?) -> Int = { tier in
            switch choice {
            case .automatic:
                guard let tier else { return 10 }
                return tier <= device.automaticTierCap
                    ? AppleStreamQualityTier.allCases.count - tier.index
                    : 20 + tier.index
            case .tier(let wanted):
                guard let tier else { return 10 }
                return tier == wanted ? 0 : 1 + abs(tier.index - wanted.index) * 2 + (tier > wanted ? 1 : 0)
            }
        }
        return candidates.enumerated().map { offset, candidate in
            let traits = traits(of: candidate)
            let contradicts = mismatched[offset]
                || (episode.map { contradictsEpisode(candidate, season: $0.season, episode: $0.episode) } ?? false)
            let down = candidate.serviceKey.map(unhealthyServices.contains) ?? false
            let preferred = preferredService != nil && candidate.serviceKey == preferredService
            return (candidate, offset, contradicts, isPlayable(traits, on: device), tierRank(traits.tier),
                    playbackClass(traits), dynamicRangeScore(traits.dynamicRange, on: device), down, preferred,
                    AppleStreamPlaceholderPolicy.isPlaceholder(candidate),
                    stockPlayerOnly ? stockPlayerScore(traits) : 0)
        }
        .sorted { a, b in
            // A provider's error clip goes last, below even another title.
            if a.9 != b.9 { return !a.9 }
            if a.2 != b.2 { return !a.2 }
            // The Native (stock) player cannot open Matroska or TS: a release
            // it plays comes first, the rest stay as fallbacks (Apple TV
            // check 2026-10-01: next episode picked an MKV → Playback Failed).
            // Among those, an explicit MP4 before an unknown container.
            if a.10 != b.10 { return a.10 > b.10 }
            if a.3 != b.3 { return a.3 }
            if a.7 != b.7 { return !a.7 }
            if a.4 != b.4 { return a.4 < b.4 }
            // The next episode keeps to the service the last one played from,
            // within the same picture tier.
            if a.8 != b.8 { return a.8 }
            if a.5 != b.5 { return a.5 < b.5 }
            if a.6 != b.6 { return a.6 > b.6 }
            return a.1 < b.1
        }
        .map(\.0)
    }
}

private extension AppleStreamQualityTier {
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
