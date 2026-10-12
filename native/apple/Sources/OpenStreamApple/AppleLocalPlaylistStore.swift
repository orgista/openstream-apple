import Foundation

/// M3U text the viewer pasted or picked from a file. Everything pasted lands
/// in ONE playlist file, so the Sources list shows one row for all of it
/// (owner, 2026-09-17: "grouped into 'source' … same as xtream") instead of a
/// row per paste. The source's URL is a stable app scheme, not a `file://`
/// path — app containers move between installs and a file URL would go stale.
public struct AppleLocalPlaylistStore: Sendable {
    public static let scheme = "openstream-playlist"
    /// The one merged playlist every paste and upload joins.
    public static let pastedURL = URL(string: "\(scheme)://local/pasted.m3u")!

    public let directory: URL
    /// Where a compressed copy of each playlist is kept when the file may be
    /// purged. Apple TV guarantees no local file storage: the system may
    /// reclaim anything outside user defaults and iCloud when space runs low
    /// ("tvOS apps have limited persistent local storage"), and a pasted
    /// playlist cannot be fetched again, unlike the channel cache or channel
    /// health history, which rebuild themselves. Nil elsewhere: Application
    /// Support is kept on iPhone, iPad, Mac and Vision Pro. Held as a
    /// defaults suite name (`standardMirror` for the app's own defaults) so
    /// the store stays `Sendable`.
    public let mirrorSuite: String?
    public static let standardMirror = "standard"

    public init(directory: URL, mirrorSuite: String? = nil) {
        self.directory = directory
        self.mirrorSuite = mirrorSuite
    }

    private var mirror: UserDefaults? {
        guard let mirrorSuite else { return nil }
        return mirrorSuite == Self.standardMirror ? .standard : UserDefaults(suiteName: mirrorSuite)
    }

    public static let shared: AppleLocalPlaylistStore = {
        let base = AppleStorageLocation.applicationSupport
        #if os(tvOS)
        let mirror: String? = standardMirror
        #else
        let mirror: String? = nil
        #endif
        return AppleLocalPlaylistStore(directory: base.appending(path: "OpenStream/Playlists"), mirrorSuite: mirror)
    }()

    /// The largest compressed playlist kept in user defaults. tvOS ends an
    /// app whose defaults pass 1 MB, and the settings live there too; a
    /// playlist over this stays file-only and has to be pasted again if the
    /// system purges it.
    public static let mirrorLimit = 256 * 1024
    static let mirrorKeyPrefix = "openstream.localPlaylist.v1."

    public static func isLocal(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Accepts the app's own playlist URLs untouched; nil for anything else.
    public static func localURL(from text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              isLocal(url), url.host == "local",
              url.lastPathComponent.hasSuffix(".m3u") else { return nil }
        return url
    }

    public func fileURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        let allowed = !name.isEmpty && name != "." && name != ".." && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
        return directory.appending(path: allowed ? name : ApplePlaybackIdentity.digest(for: url.absoluteString) + ".m3u")
    }

    public func read(_ url: URL) throws -> Data {
        let file = fileURL(for: url)
        do {
            return try Data(contentsOf: file)
        } catch {
            // Purged: put the file back from the mirror and carry on.
            guard let restored = mirrored(url) else { throw error }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? restored.write(to: file, options: .atomic)
            return restored
        }
    }

    /// The mirror's copy of `url`, decompressed; nil without one.
    func mirrored(_ url: URL) -> Data? {
        guard let stored = mirror?.data(forKey: Self.mirrorKeyPrefix + url.lastPathComponent) else { return nil }
        return try? (stored as NSData).decompressed(using: .zlib) as Data
    }

    /// Keeps a compressed copy in the mirror when it fits; drops a stale one
    /// that no longer does, so a purge never brings back an older playlist.
    private func updateMirror(_ data: Data, for url: URL) {
        guard let mirror else { return }
        let key = Self.mirrorKeyPrefix + url.lastPathComponent
        if let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
           compressed.count <= Self.mirrorLimit {
            mirror.set(compressed, forKey: key)
        } else {
            mirror.removeObject(forKey: key)
        }
    }

    public func text(_ url: URL) -> String? {
        (try? read(url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Merges pasted text into the playlist at `url` and writes it atomically.
    @discardableResult
    public func merge(text: String, into url: URL = pastedURL) throws -> AppleM3UTextMerger.Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = AppleM3UTextMerger.merge(existing: self.text(url), incoming: text)
        let data = Data(result.text.utf8)
        try data.write(to: fileURL(for: url), options: .atomic)
        updateMirror(data, for: url)
        return result
    }
}

/// Pure M3U merge: entries are keyed by stream URL, the first copy wins, and
/// each entry keeps every `#EXT…` directive that preceded its URL.
public enum AppleM3UTextMerger {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let added: Int
        public let total: Int
    }

    public struct Entry: Equatable, Sendable {
        public var directives: [String]
        public var url: String
    }

    public static func merge(existing: String?, incoming: String) -> Result {
        let old = parse(existing ?? "")
        let new = parse(incoming)
        var seen = Set(old.entries.map(\.url))
        var entries = old.entries
        var added = 0
        for entry in new.entries where !seen.contains(entry.url) {
            seen.insert(entry.url)
            entries.append(entry)
            added += 1
        }
        // Keep the header we had; take the incoming one when ours carries no
        // guide (`url-tvg`) and theirs does, or when we had none at all.
        var header = old.header ?? new.header ?? "#EXTM3U"
        if let theirs = new.header, !header.contains("url-tvg"), theirs.contains("url-tvg") {
            header = theirs
        }
        var lines = [header]
        for entry in entries {
            lines.append(contentsOf: entry.directives)
            lines.append(entry.url)
        }
        return Result(text: lines.joined(separator: "\n") + "\n", added: added, total: entries.count)
    }

    public static func parse(_ text: String) -> (header: String?, entries: [Entry]) {
        var header: String?
        var entries: [Entry] = []
        var pending: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") {
                if header == nil { header = line }
                continue
            }
            if line.hasPrefix("#") {
                pending.append(line)
                continue
            }
            entries.append(Entry(directives: pending, url: line))
            pending = []
        }
        return (header, entries)
    }
}
