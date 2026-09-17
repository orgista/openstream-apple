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

    public init(directory: URL) {
        self.directory = directory
    }

    public static let shared: AppleLocalPlaylistStore = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return AppleLocalPlaylistStore(directory: base.appending(path: "OpenStream/Playlists"))
    }()

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
        directory.appending(path: url.lastPathComponent)
    }

    public func read(_ url: URL) throws -> Data {
        try Data(contentsOf: fileURL(for: url))
    }

    public func text(_ url: URL) -> String? {
        (try? read(url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Merges pasted text into the playlist at `url` and writes it atomically.
    @discardableResult
    public func merge(text: String, into url: URL = pastedURL) throws -> AppleM3UTextMerger.Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = AppleM3UTextMerger.merge(existing: self.text(url), incoming: text)
        try Data(result.text.utf8).write(to: fileURL(for: url), options: .atomic)
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
