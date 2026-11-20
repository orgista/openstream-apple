import Foundation

/// Derived playback metadata. References are opaque file identities, never transport URLs.
public struct AppleMediaPart: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ordinal: Int
    public var duration: Double?
    public let reference: String

    public init(id: String, ordinal: Int, duration: Double?, reference: String) {
        self.id = id
        self.ordinal = ordinal
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.reference = reference
    }
}

public struct AppleMediaVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let itemID: String
    public let sourceID: UUID
    public let label: String
    public var parts: [AppleMediaPart]
    public var providerVersionID: String?
    public var descriptors: AppleStreamDescriptors = .init()
    public var lastVerified: Date = .now
    /// Optional so earlier v1 cache entries remain decodable.
    public var badgeValues: [Int]? = nil

    public var formatBadges: [AppleStreamFormatBadge] {
        get { badgeValues.map { $0.compactMap(AppleStreamFormatBadge.init(rawValue:)) } ?? AppleStreamFormatBadge.parse(label) }
        set { badgeValues = AppleStreamFormatBadge.normalized(newValue).map(\.rawValue) }
    }

    /// Context menus use the system's text rows, carrying the same probed badge values.
    public var menuLabel: String {
        let extra = formatBadges.filter { !$0.isResolution && !label.localizedCaseInsensitiveContains($0.title) }.map(\.title)
        return ([label] + extra).joined(separator: " · ")
    }

    public var quality: (resolution: Int, dynamicRange: Int, bitrate: Int) {
        let badges = formatBadges
        let named = AppleReleaseName.resolution(label)
        let resolution = descriptors.height ?? max(named, badges.contains(.uhd) ? 2160 : badges.contains(.fullHD) ? 1080 : 0)
        let range = badges.contains(.dolbyVision) ? 3 : badges.contains(.hdr10Plus) ? 2 : badges.contains(.hdr10) ? 1 : 0
        return (resolution, range, descriptors.bitrate ?? 0)
    }

    public init(id: String, itemID: String, sourceID: UUID, label: String, parts: [AppleMediaPart], providerVersionID: String? = nil) {
        self.id = id
        self.itemID = itemID
        self.sourceID = sourceID
        self.label = label
        self.parts = parts.sorted { $0.ordinal < $1.ordinal }
        self.providerVersionID = providerVersionID
    }

    public var duration: Double? {
        guard !parts.isEmpty, parts.allSatisfy({ $0.duration != nil }) else { return nil }
        return parts.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    public struct Location: Equatable, Sendable {
        public let ordinal: Int
        public let offset: Double
    }

    public func location(at position: Double) -> Location? {
        guard position.isFinite, position >= 0 else { return nil }
        var remaining = position
        for part in parts {
            guard let duration = part.duration else { return nil }
            if remaining < duration || part == parts.last {
                return Location(ordinal: part.ordinal, offset: min(remaining, duration))
            }
            remaining -= duration
        }
        return nil
    }

    public func cumulativePosition(ordinal: Int, offset: Double) -> Double? {
        guard offset.isFinite, offset >= 0, parts.contains(where: { $0.ordinal == ordinal }) else { return nil }
        let preceding = parts.filter { $0.ordinal < ordinal }
        guard preceding.allSatisfy({ $0.duration != nil }) else { return nil }
        return preceding.reduce(offset) { $0 + ($1.duration ?? 0) }
    }

    public func isAvailable(references: Set<String>) -> Bool {
        !parts.isEmpty && parts.allSatisfy { references.contains($0.reference) }
    }
}

enum AppleVersionResumePolicy {
    struct Resolution: Equatable {
        let position: Double?
        let needsConfirmation: Bool
    }

    static func resolve(own: ApplePlaybackProgress?, item: ApplePlaybackProgress?, duration: Double?) -> Resolution {
        if let own, item.map({ own.updatedAt >= $0.updatedAt }) ?? true {
            return Resolution(position: own.resumePosition, needsConfirmation: false)
        }
        guard let item, let position = item.resumePosition else { return Resolution(position: nil, needsConfirmation: false) }
        let differs = duration.map { $0 > 0 && item.duration > 0 && abs($0 - item.duration) / item.duration > 0.02 } ?? false
        return Resolution(position: position, needsConfirmation: differs)
    }
}

/// The prompt names the version it asked about; answering plays that version.
public struct AppleVersionResumeConfirmation: Error, Equatable {
    public let position: Double
    public let versionID: String
}

/// Owner rule 2026-10-15: the copy played most recently is the resume copy.
/// When it is gone (replaced, or its share unmounted) Play falls back to the
/// best available version for this play only; the record is kept.
enum AppleVersionSelectionPolicy {
    /// `available` is quality-ordered, best first.
    static func select(_ available: [AppleMediaVersion], confirmed: String? = nil, lastPlayed: String?,
                       requestedReference: String?) -> AppleMediaVersion? {
        if let confirmed, let version = available.first(where: { $0.id == confirmed }) { return version }
        if let lastPlayed {
            return available.first { $0.id == lastPlayed } ?? available.first
        }
        return available.first { version in version.parts.contains { $0.reference == requestedReference } } ?? available.first
    }
}

/// A rebuildable cache, separate from the playback state and configuration snapshot.
@MainActor final class AppleMediaVersionCache {
    /// One writer for `MediaVersions-v1.json`: local files and media servers share it.
    static let shared = AppleMediaVersionCache()

    private let url: URL
    private(set) var versions: [String: AppleMediaVersion]
    private var versionByReference: [String: String] = [:]

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenStream").appendingPathComponent("MediaVersions-v1.json")
        versions = (try? Data(contentsOf: self.url)).flatMap {
            try? JSONDecoder().decode([String: AppleMediaVersion].self, from: $0)
        } ?? [:]
        rebuildReferenceIndex()
    }

    private func rebuildReferenceIndex() {
        versionByReference = [:]
        for version in versions.values {
            for part in version.parts { versionByReference[part.reference] = version.id }
        }
    }

    func version(containing reference: String) -> AppleMediaVersion? {
        versionByReference[reference].flatMap { versions[$0] }
    }

    func versions(itemID: String) -> [AppleMediaVersion] {
        versions.values.filter { $0.itemID == itemID }
    }

    /// A part the probe could not measure learns its length from playback, so
    /// the next play has the whole cumulative timeline.
    func learnDuration(_ duration: Double, reference: String) {
        guard duration.isFinite, duration > 0, var version = version(containing: reference),
              let index = version.parts.firstIndex(where: { $0.reference == reference }),
              version.parts[index].duration == nil else { return }
        version.parts[index].duration = duration
        record([version])
    }

    func record(_ values: [AppleMediaVersion]) {
        // A fresher `lastVerified` alone stays in memory: every launch rebuilds
        // versions with `.now`, and the next real change persists it.
        let changed = values.contains { value in
            guard let old = versions[value.id] else { return true }
            return old.parts != value.parts || old.itemID != value.itemID || old.label != value.label || old.descriptors != value.descriptors || old.formatBadges != value.formatBadges
        }
        for value in values { versions[value.id] = value }
        guard changed else { return }
        // Bound rebuildable metadata; no progress is stored here.
        if versions.count > 10_000 {
            versions = Dictionary(uniqueKeysWithValues: versions.values.sorted { $0.lastVerified > $1.lastVerified }
                .prefix(10_000).map { ($0.id, $0) })
        }
        rebuildReferenceIndex()
        if heldWrites > 0 { pendingWrite = true } else { write() }
    }

    private var heldWrites = 0
    private var pendingWrite = false
    /// Whole-file writes of `MediaVersions-v1.json`.
    private(set) var diskWrites = 0

    /// A library publish records every title; the file is written once at the end.
    func recordInOneWrite(_ body: @MainActor () async -> Void) async {
        heldWrites += 1
        await body()
        heldWrites -= 1
        if heldWrites == 0, pendingWrite { write() }
    }

    private func write() {
        pendingWrite = false
        diskWrites += 1
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(versions) { try? data.write(to: url, options: .atomic) }
    }
}
