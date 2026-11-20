import Foundation

public enum AppleLibrarySourceError: Error, Equatable, LocalizedError, Sendable {
    case invalidFolder
    case unavailable
    /// A network share that did not answer: it may be off, asleep or not
    /// allowed yet (the Local Network prompt), not gone.
    case unreachable
    case permissionDenied
    case noMedia

    public var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose a folder from Files."
        case .unavailable: "This folder is no longer available."
        case .unreachable: "Can't reach this share."
        case .permissionDenied: "oStream no longer has permission to read this folder."
        case .noMedia: "No video files were found."
        }
    }
}

/// When Library scans again by itself after a network share did not answer.
///
/// On a fresh install the first scan runs while the Local Network prompt is
/// still up, so every share fails, and Library kept the failure until the
/// viewer tapped Refresh (build 20 B5). Nothing tells the app when the prompt
/// is answered beyond the app becoming active again, so it also scans again on
/// a widening schedule; a scan that reaches every share starts the count over.
enum AppleLibraryShareRetryPolicy {
    static let delays: [Duration] = [.seconds(3), .seconds(10), .seconds(30), .seconds(60), .seconds(120)]

    /// The wait before the next scan, or nil for none. `attempt` counts the
    /// retries since the last scan that reached every share.
    static func delay(unreachableShares: Int, attempt: Int, delays: [Duration] = delays) -> Duration? {
        guard unreachableShares > 0, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}

public struct AppleLibraryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceID: AppleSource.ID
    public let name: String
    public let url: URL
    public let relativePath: String
    public let sizeBytes: Int64
    public let addedAt: Date
    /// When the share last saw the file change; nil for folders that do not say.
    public let modifiedAt: Date?

    public init(
        sourceID: AppleSource.ID,
        name: String,
        url: URL,
        relativePath: String,
        sizeBytes: Int64,
        addedAt: Date = .distantPast,
        modifiedAt: Date? = nil
    ) {
        id = "\(sourceID.uuidString):\(relativePath)"
        self.sourceID = sourceID
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
    }
}

public enum AppleLibraryBookmark {
    public static func make(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public static func resolve(_ source: AppleSource) throws -> URL {
        guard source.kind == .library, source.url.isFileURL else { throw AppleLibrarySourceError.invalidFolder }
        guard let bookmark = source.bookmarkData else { return source.url }
        var stale = false
        #if os(macOS)
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #else
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #endif
        guard !stale else { throw AppleLibrarySourceError.permissionDenied }
        return url
    }
}

public final class AppleSecurityScopedAccess {
    public let url: URL
    private let didStart: Bool

    public init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

public actor AppleLibraryScanner {
    public static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "ts", "m2ts", "avi", "wmv",
        // Disc images: the engine plays them through its disc adapter.
        "iso",
    ]

    private let fileManager: FileManager
    private let maximumItems: Int

    public init(fileManager: FileManager = .default, maximumItems: Int = 5_000) {
        self.fileManager = fileManager
        self.maximumItems = max(1, maximumItems)
    }

    public func scan(source: AppleSource) throws -> [AppleLibraryItem] {
        try snapshot(source: source).items
    }

    public func scanResult(source: AppleSource) -> AppleLibraryScanResult {
        do { return try snapshot(source: source) }
        catch { return AppleLibraryScanResult(items: [], status: .failed) }
    }

    private func snapshot(source: AppleSource) throws -> AppleLibraryScanResult {
        try Task.checkCancellation()
        let root = try AppleLibraryBookmark.resolve(source)
        let access = AppleSecurityScopedAccess(url: root)
        defer { withExtendedLifetime(access) {} }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppleLibrarySourceError.unavailable
        }
        var incomplete = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in incomplete = true; return true }
        ) else { throw AppleLibrarySourceError.permissionDenied }

        var items: [AppleLibraryItem] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard items.count < maximumItems else { incomplete = true; break }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .creationDateKey]) else {
                incomplete = true
                continue
            }
            guard values.isRegularFile == true else { continue }
            let rootPath = root.standardizedFileURL.path.hasSuffix("/")
                ? root.standardizedFileURL.path
                : root.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
            items.append(AppleLibraryItem(
                sourceID: source.id,
                name: values.name ?? url.deletingPathExtension().lastPathComponent,
                url: url,
                relativePath: relative,
                sizeBytes: Int64(values.fileSize ?? 0),
                addedAt: values.creationDate ?? .distantPast
            ))
        }
        return AppleLibraryScanResult(items: items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            status: incomplete ? .partial : .complete)
    }
}
