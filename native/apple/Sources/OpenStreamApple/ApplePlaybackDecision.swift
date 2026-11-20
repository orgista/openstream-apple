import Foundation
import VideoToolbox

public struct AppleStreamDescriptors: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var container: String?
    public var videoCodec: String?
    public var videoLevel: Double?
    public var dolbyVisionProfile: Int?
    public var audioCodec: String?
    public var subtitleCodec: String?
    public var bitrate: Int?
    public var duration: Double?

    public init(container: String? = nil, videoCodec: String? = nil, videoLevel: Double? = nil,
                dolbyVisionProfile: Int? = nil, audioCodec: String? = nil, subtitleCodec: String? = nil,
                bitrate: Int? = nil, duration: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
        self.container = container
        self.videoCodec = videoCodec
        self.videoLevel = videoLevel
        self.dolbyVisionProfile = dolbyVisionProfile
        self.audioCodec = audioCodec
        self.subtitleCodec = subtitleCodec
        self.bitrate = bitrate
        self.duration = duration
    }
}

public struct AppleDeviceCapabilities: Equatable, Sendable {
    public var maximumVideoWidth: Int = 4096
    public var maximumVideoHeight: Int = 2160
    public var hardwareH264Level: Double = 5.1
    public var hardwareHEVCLevel: Double = 5.1
    public var hardwareAV1: Bool = false
    public var nativeVideoCodecs: Set<String> = ["h264", "hevc", "mpeg4"]
    public var nativeAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "flac", "alac", "mp3", "pcm_s16le", "pcm_s24le"]
    public init() {}

    static var current: Self {
        var capabilities = Self()
        if !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            capabilities.nativeVideoCodecs.remove("hevc")
        }
        capabilities.hardwareAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        return capabilities
    }
}

public struct ApplePlaybackDecision: Equatable, Sendable {
    public enum Video: Equatable, Sendable { case originalBytes, localSoftwareDecode, serverTranscode }
    public enum Audio: Equatable, Sendable { case passthrough, localDecode(String), serverTranscode }
    public enum Subtitle: Equatable, Sendable { case embedded, none, serverBurnIn }
    public enum Reason: Equatable, Sendable {
        case containerNotNative, videoLevelAboveHardware(Double), dolbyVisionProfileUnsupported(Int)
        case audioCodecUnsupported(String), videoCodecUnsupported(String), bitrateAboveRouteLimit, engineFailure
    }
    public var video: Video
    public var audio: Audio
    public var subtitle: Subtitle
    public var reasons: [Reason]

    public static func decide(_ descriptors: AppleStreamDescriptors, remote: Bool = false, failedOriginal: Bool = false,
                              capabilities: AppleDeviceCapabilities = .init()) -> Self {
        var reasons: [Reason] = []
        var video: Video = .originalBytes
        var audio: Audio = .passthrough
        if let container = descriptors.container?.lowercased(), !["mp4", "mov", "m4v", "m3u8"].contains(container) {
            reasons.append(.containerNotNative)
        }
        if let codec = descriptors.videoCodec?.lowercased(),
           !capabilities.nativeVideoCodecs.contains(codec), !(codec == "av1" && capabilities.hardwareAV1) {
            reasons.append(.videoCodecUnsupported(codec))
            if !remote { video = .localSoftwareDecode }
        }
        if let level = descriptors.videoLevel, level > capabilities.hardwareHEVCLevel {
            reasons.append(.videoLevelAboveHardware(level))
            video = remote ? .originalBytes : .localSoftwareDecode
        }
        if let profile = descriptors.dolbyVisionProfile, ![5, 8].contains(profile) {
            reasons.append(.dolbyVisionProfileUnsupported(profile))
        }
        if let codec = descriptors.audioCodec?.lowercased(), !capabilities.nativeAudioCodecs.contains(codec) {
            reasons.append(.audioCodecUnsupported(codec))
            audio = .localDecode(codec)
        }
        if failedOriginal { reasons.append(.engineFailure) }
        return Self(video: video, audio: audio,
                    subtitle: descriptors.subtitleCodec == nil ? .none : .embedded, reasons: reasons)
    }

    public func mismatch(observedSoftwareDecode: Bool) -> Bool {
        (video == .localSoftwareDecode) != observedSoftwareDecode
    }
}

enum AppleJellyfinPlaybackPolicy {
    enum Route: Equatable { case original, conversion }
    static func select(_ sources: [AppleMediaServerPlaybackInfo.MediaSource], failed: Set<String>, preferred: String? = nil,
                       defaultMediaSourceID: String? = nil, capabilities: AppleDeviceCapabilities = .current) -> AppleMediaServerPlaybackInfo.MediaSource? {
        if let preferred, !failed.contains(preferred), let source = sources.first(where: { $0.id == preferred }) { return source }
        return ranked(sources, failed: failed, defaultMediaSourceID: defaultMediaSourceID, capabilities: capabilities).first
    }

    /// Keep the server's prepared/default source and order; conversions and placeholders come last.
    static func ranked(_ sources: [AppleMediaServerPlaybackInfo.MediaSource], failed: Set<String>,
                       defaultMediaSourceID: String? = nil, capabilities: AppleDeviceCapabilities = .current) -> [AppleMediaServerPlaybackInfo.MediaSource] {
        let available = sources.filter { !failed.contains($0.id) }
        var direct = available.filter { !$0.isPlaceholder && canDirectPlay($0, capabilities: capabilities) }
        if let index = direct.firstIndex(where: { $0.id == defaultMediaSourceID }) {
            direct.insert(direct.remove(at: index), at: 0)
        }
        let conversions = available.filter {
            !$0.isPlaceholder && !canDirectPlay($0, capabilities: capabilities) && $0.transcodingURLPath != nil
        }
        return direct + conversions + available.filter(\.isPlaceholder)
    }
    static func route(for source: AppleMediaServerPlaybackInfo.MediaSource, afterFailure: Bool,
                      capabilities: AppleDeviceCapabilities = .current) -> Route {
        source.transcodingURLPath != nil && (afterFailure || !canDirectPlay(source, capabilities: capabilities)) ? .conversion : .original
    }

    static func canDirectPlay(_ source: AppleMediaServerPlaybackInfo.MediaSource,
                              capabilities: AppleDeviceCapabilities) -> Bool {
        guard source.supportsDirectPlay || source.supportsDirectStream || source.remoteURL != nil else { return false }
        return canDecodeVideo(source, capabilities: capabilities)
    }

    private static func canDecodeVideo(_ source: AppleMediaServerPlaybackInfo.MediaSource,
                                       capabilities: AppleDeviceCapabilities) -> Bool {
        let descriptors = source.descriptors
        if let width = descriptors.width, width > capabilities.maximumVideoWidth { return false }
        let height = max(descriptors.height ?? 0, AppleReleaseName.resolution(source.name ?? ""))
        guard height <= capabilities.maximumVideoHeight else { return false }
        if let profile = descriptors.dolbyVisionProfile, ![5, 8].contains(profile) { return false }
        guard let rawCodec = descriptors.videoCodec?.lowercased() else { return true }
        let codec: String
        switch rawCodec {
        case "avc", "avc1", "avc3", "x264": codec = "h264"
        case "h265", "hvc1", "hev1", "x265", "dvhe", "dvh1": codec = "hevc"
        default: codec = rawCodec
        }
        guard capabilities.nativeVideoCodecs.contains(codec) || codec == "av1" && capabilities.hardwareAV1 else { return false }
        if let level = descriptors.videoLevel {
            if codec == "hevc", level > capabilities.hardwareHEVCLevel { return false }
            if codec == "h264", level > capabilities.hardwareH264Level { return false }
        }
        return true
    }

    /// The source's external subtitles, as tracks the player loads on pick.
    /// A path on the server itself gets the session token; a file on
    /// another host is fetched as given.
    static func externalSubtitles(_ source: AppleMediaServerPlaybackInfo.MediaSource,
                                  session: AppleMediaServerSession) -> [AppleExternalSubtitleTrack] {
        source.mediaStreams.compactMap { stream -> AppleExternalSubtitleTrack? in
            guard stream.isSubtitle, stream.isExternal || stream.deliveryMethod?.lowercased() == "external",
                  let path = stream.deliveryURLPath, let resolved = URL(string: path, relativeTo: session.baseURL)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? ""),
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
            if sameOrigin(resolved, session.baseURL),
               !(components.queryItems ?? []).contains(where: { $0.name.lowercased() == "api_key" }) {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: session.accessToken)]
            }
            guard let url = components.url else { return nil }
            let name = [stream.title, stream.isForced ? "Forced" : nil].compactMap { $0 }.joined(separator: " ")
            return AppleExternalSubtitleTrack(id: "server:\(source.id):\(stream.index.map(String.init) ?? path)",
                languageCode: stream.language ?? "", sourceName: name.isEmpty ? nil : name, url: url)
        }
    }

    /// Same scheme, host and port (the scheme's default when unstated): only
    /// then does a link get the session token, so it never goes to another
    /// host or over plain http from an https server.
    static func sameOrigin(_ url: URL, _ base: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let a = origin(url), let b = origin(base) else { return false }
        return a == b
    }

    static func conversionURL(_ path: String, session: AppleMediaServerSession, audioStreamIndex: Int? = nil, audioOnly: Bool = false, videoCodec: String? = nil) throws -> URL {
        guard let url = URL(string: path, relativeTo: session.baseURL)?.absoluteURL,
              url.scheme == session.baseURL.scheme, url.host == session.baseURL.host,
              url.port == session.baseURL.port else { throw AppleMediaServerError.unsupported }
        guard audioOnly else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AppleMediaServerError.unsupported }
        var overrides = ["AllowVideoStreamCopy": "true", "AllowAudioStreamCopy": "false", "AudioCodec": "aac"]
        if let videoCodec, !videoCodec.isEmpty { overrides["VideoCodec"] = videoCodec }
        let names = Set(overrides.keys.map { $0.lowercased() })
        var query = (components.queryItems ?? []).filter { !names.contains($0.name.lowercased()) && $0.name.lowercased() != "audiostreamindex" }
        query += overrides.keys.sorted().map { URLQueryItem(name: $0, value: overrides[$0]) }
        if let audioStreamIndex { query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex))) }
        components.queryItems = query
        guard let result = components.url else { throw AppleMediaServerError.unsupported }
        return result
    }

    static func conversionDecision(for source: AppleMediaServerPlaybackInfo.MediaSource) -> ApplePlaybackDecision {
        var decision = ApplePlaybackDecision.decide(source.descriptors, remote: true, failedOriginal: true)
        let audioOnly = isAudioOnlyMismatch(source)
        decision.video = audioOnly ? .originalBytes : .serverTranscode
        decision.audio = .serverTranscode
        return decision
    }

    static func isAudioOnlyMismatch(_ source: AppleMediaServerPlaybackInfo.MediaSource) -> Bool {
        guard canDecodeVideo(source, capabilities: .current) else { return false }
        let reasons = ApplePlaybackDecision.decide(source.descriptors, remote: true).reasons
        return reasons.contains { if case .audioCodecUnsupported = $0 { true } else { false } }
            && !reasons.contains { reason in
                switch reason {
                case .videoCodecUnsupported, .videoLevelAboveHardware, .dolbyVisionProfileUnsupported, .bitrateAboveRouteLimit: true
                default: false
                }
            }
    }

    /// Aether accepts original containers and decodes unsupported audio locally.
    /// No bitrate limit or speculative codec restriction asks the server to lower quality.
    static var deviceProfile: [String: Any] {
        ["Name": "oStream",
         "DirectPlayProfiles": [["Type": "Video"], ["Type": "Audio"]],
         "TranscodingProfiles": [["Type": "Video", "Context": "Streaming", "Protocol": "hls",
                                    "Container": "ts", "VideoCodec": "h264", "AudioCodec": "aac", "CopyTimestamps": true]]]
    }
}

enum ApplePlaybackFallbackPolicy {
    enum Step: Equatable { case conversion, nextVersion, unavailable }
    static func next(triedConversion: Bool, nextVersionAvailable: Bool) -> Step {
        if !triedConversion { return .conversion }
        return nextVersionAvailable ? .nextVersion : .unavailable
    }
}
