import Foundation

public enum AppleChannelHealthBucket: String, Codable, Sendable {
    case online, reachable, timeout, offline
    /// The provider refused the probe (403/429, its connection limit): unknown, not offline.
    case busy
}

/// Contains no locator, headers, provider text, or localized error descriptions.
public struct AppleChannelHealthResult: Codable, Equatable, Sendable {
    public let channelID: String
    public let bucket: AppleChannelHealthBucket
    public let failedStage: AppleSavedSourceDiagnosticStage?
    public let httpStatus: Int?
    public let ttfbMs: Int?
    public let checkedAt: Date
    public let videoInfo: AppleChannelHealthVideoInfo?
    public var probeKind: AppleSavedSourceDiagnosticProbeKind { .iptv }

    /// Reuses the failure vocabulary consumed by AppleLiveFailurePresentation.
    public var failureKind: ApplePlaybackFailure.Kind? {
        if bucket == .online || bucket == .busy { return nil }
        if httpStatus == 401 || httpStatus == 403 { return .authentication }
        if bucket == .timeout { return .timedOut }
        if bucket == .offline { return httpStatus == nil ? .network : .unavailable }
        return .unsupportedMedia
    }

    public init(channelID: String, bucket: AppleChannelHealthBucket,
                failedStage: AppleSavedSourceDiagnosticStage? = nil, httpStatus: Int? = nil,
                ttfbMs: Int? = nil, checkedAt: Date = .now,
                videoInfo: AppleChannelHealthVideoInfo? = nil) {
        self.channelID = Self.storageID(channelID)
        self.bucket = bucket
        self.failedStage = failedStage
        self.httpStatus = httpStatus
        self.ttfbMs = ttfbMs
        self.checkedAt = checkedAt
        self.videoInfo = videoInfo
    }

    /// App IDs are opaque. Defensively hash a caller-supplied locator instead of saving it.
    public static func storageID(_ id: String) -> String {
        if !id.isEmpty, id.utf8.count <= 160,
           id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-").contains($0) }) {
            return id
        }
        return ApplePlaybackIdentity.digest(for: id)
    }
}

public struct AppleChannelHealthVideoInfo: Codable, Equatable, Sendable {
    public let codec: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let hasVideo: Bool

    public init(codec: String?, width: Int?, height: Int?, fps: Double?, hasVideo: Bool) {
        // Codec names come from libav, never container metadata.
        self.codec = codec.flatMap { value in
            value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0)
            } ? value : nil
        }
        self.width = width.flatMap { $0 > 0 ? $0 : nil }
        self.height = height.flatMap { $0 > 0 ? $0 : nil }
        self.fps = fps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.hasVideo = hasVideo
    }
}

/// Atomic JSON, matching AppleIPTVChannelCache and AppleLocalPlaylistStore.
/// One small file per channel avoids tvOS's 1 MB UserDefaults termination limit
/// and avoids rewriting the entire lineup after every completed probe.
/// Apple TV may purge these files when storage runs low; that is safe, as the
/// history is only what past probes saw and the next probes rebuild it.
public actor AppleChannelHealthHistory {
    public static let shared = AppleChannelHealthHistory()
    public struct Entry: Codable, Equatable, Sendable {
        public var lastResult: AppleChannelHealthResult { outcomes[outcomes.count - 1] }
        /// Oldest to newest, including lastResult; at most five by default.
        public fileprivate(set) var outcomes: [AppleChannelHealthResult]
    }
    private let directory: URL
    private let limit: Int

    public init(directory: URL? = nil, limit: Int = 5) {
        self.directory = directory ?? AppleStorageLocation.applicationSupport
            .appending(path: "OpenStream/ChannelHealth")
        self.limit = max(1, limit)
    }

    public func entry(channelID: String) -> Entry? {
        read(fileURL(channelID: AppleChannelHealthResult.storageID(channelID)))
    }

    public func snapshot() -> [String: Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        var entries: [String: Entry] = [:]
        for file in files where file.pathExtension == "json" {
            if let entry = read(file) { entries[entry.lastResult.channelID] = entry }
        }
        return entries
    }

    public func record(_ result: AppleChannelHealthResult) throws {
        var outcomes = entry(channelID: result.channelID)?.outcomes ?? []
        outcomes.append(result)
        outcomes.sort { $0.checkedAt < $1.checkedAt }
        let entry = Entry(outcomes: Array(outcomes.suffix(limit)))
        let data = try JSONEncoder().encode(entry)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(channelID: result.channelID), options: .atomic)
    }

    private func fileURL(channelID: String) -> URL {
        directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: channelID) + ".json")
    }
    private func read(_ file: URL) -> Entry? {
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              !entry.outcomes.isEmpty else { return nil }
        return Entry(outcomes: Array(entry.outcomes.suffix(limit)))
    }
}
