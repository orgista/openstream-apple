import Foundation

public enum AppleLibrarySourceError: Error, Equatable, LocalizedError, Sendable {
    case invalidFolder
    case unavailable
    case permissionDenied
    case noMedia

    public var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose a folder from Files."
        case .unavailable: "This folder is no longer available."
        case .permissionDenied: "OpenStream no longer has permission to read this folder."
        case .noMedia: "No video files were found."
        }
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

    public init(
        sourceID: AppleSource.ID,
        name: String,
        url: URL,
        relativePath: String,
        sizeBytes: Int64,
        addedAt: Date = .distantPast
    ) {
        id = "\(sourceID.uuidString):\(relativePath)"
        self.sourceID = sourceID
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
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
    ]

    private let fileManager: FileManager
    private let maximumItems: Int

    public init(fileManager: FileManager = .default, maximumItems: Int = 5_000) {
        self.fileManager = fileManager
        self.maximumItems = max(1, maximumItems)
    }

    public func scan(source: AppleSource) throws -> [AppleLibraryItem] {
        let root = try AppleLibraryBookmark.resolve(source)
        let access = AppleSecurityScopedAccess(url: root)
        defer { withExtendedLifetime(access) {} }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppleLibrarySourceError.unavailable
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw AppleLibrarySourceError.permissionDenied }

        var items: [AppleLibraryItem] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard items.count < maximumItems else { break }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .creationDateKey]),
                  values.isRegularFile == true else { continue }
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
        return items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
