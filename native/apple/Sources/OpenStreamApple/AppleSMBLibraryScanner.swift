import Foundation

struct AppleSMBLibraryScanResult: Sendable {
    var items: [AppleLibraryItem] = []
    var skippedFolderCount = 0
    var reachedLimit = false

    var notice: String? {
        if reachedLimit { return "Showing part of this share. Choose a smaller folder to see more videos." }
        if skippedFolderCount > 0 { return "Some folders couldn’t be opened. Videos from the other folders are available." }
        return nil
    }
}

/// Enumerate one directory at a time: a denied child must not discard the
/// readable files in the rest of the share or keep Library loading forever.
struct AppleSMBLibraryScanner: Sendable {
    let client: any AppleNetworkShareClient
    let maximumItems: Int
    let maximumFolders: Int
    let maximumDepth: Int

    init(client: any AppleNetworkShareClient, maximumItems: Int = 5_000,
         maximumFolders: Int = 256, maximumDepth: Int = 16) {
        self.client = client
        self.maximumItems = max(1, maximumItems)
        self.maximumFolders = max(1, maximumFolders)
        self.maximumDepth = max(0, maximumDepth)
    }

    /// Download-client staging, NAS recycle bins and hidden folders hold
    /// leftover copies of titles the library already has. Skipped only when
    /// found beneath the selected folder; choosing one as the source still
    /// scans it.
    static let stagingFolderNames: Set<String> = [
        "downloads", "download", "incomplete", "#recycle", "@eadir", "$recycle.bin",
    ]

    static func isStagingFolder(_ name: String) -> Bool {
        name.hasPrefix(".") || stagingFolderNames.contains(name.lowercased())
    }

    /// Playback-only, non-recursive discovery. Library scans never fetch sidecars.
    func siblingSubtitles(for video: URL, credentials: AppleSMBCredentials) async throws -> [AppleExternalSubtitleTrack] {
        try Task.checkCancellation()
        let folder = video.deletingLastPathComponent()
        let parts = try AppleSMBEndpointPolicy.parts(from: folder)
        let entries = try await client.listDirectory(url: folder, credentials: credentials, recursive: false)
        let urls = try entries.compactMap { entry -> URL? in
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !entry.isDirectory, entry.sizeBytes > 0,
                  entry.sizeBytes <= AppleExternalSubtitleService.maximumSubtitleBytes,
                  !path.split(separator: "/").contains(".."),
                  !path.split(separator: "/").contains("."),
                  path.split(separator: "/").dropLast().joined(separator: "/") == parts.path else { return nil }
            return try AppleSMBEndpointPolicy.makeURL(
                host: parts.host, port: parts.port, share: parts.share, path: path)
        }
        try Task.checkCancellation()
        return AppleLibrarySubtitleService.matching(video: video, files: urls)
    }

    func scan(
        source: AppleSource,
        credentials: AppleSMBCredentials,
        onProgress: (@MainActor @Sendable ([AppleLibraryItem]) -> Void)? = nil
    ) async throws -> AppleSMBLibraryScanResult {
        try Task.checkCancellation()
        let parts = try AppleSMBEndpointPolicy.parts(from: source.url)
        let root = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var pending = [(path: root, depth: 0)]
        var visited: Set<String> = [root]
        var seenFiles = Set<String>()
        var cursor = 0
        var result = AppleSMBLibraryScanResult()

        while cursor < pending.count {
            try Task.checkCancellation()
            guard cursor < maximumFolders, result.items.count < maximumItems else {
                result.reachedLimit = true
                break
            }
            let folder = pending[cursor]
            cursor += 1
            let url = try AppleSMBEndpointPolicy.makeURL(
                host: parts.host, port: parts.port, share: parts.share, path: folder.path
            )
            let entries: [AppleSMBDirectoryEntry]
            do {
                entries = try await client.listDirectory(url: url, credentials: credentials, recursive: false)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if folder.depth == 0 { throw error }
                result.skippedFolderCount += 1
                continue
            }
            try Task.checkCancellation()
            let previousCount = result.items.count
            for entry in entries {
                try Task.checkCancellation()
                let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let components = path.split(separator: "/")
                guard !components.contains(".."), !components.contains("."),
                      root.isEmpty || path.hasPrefix(root + "/") else { continue }
                if entry.isDirectory {
                    guard !visited.contains(path),
                          !Self.isStagingFolder(String(components.last ?? "")) else { continue }
                    guard folder.depth < maximumDepth, pending.count < maximumFolders else {
                        result.reachedLimit = true
                        continue
                    }
                    visited.insert(path)
                    pending.append((path, folder.depth + 1))
                } else if AppleLibraryScanner.supportedExtensions.contains(
                    URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                ), seenFiles.insert(path).inserted {
                    guard result.items.count < maximumItems else {
                        result.reachedLimit = true
                        break
                    }
                    let mediaURL = try AppleSMBEndpointPolicy.makeURL(
                        host: parts.host, port: parts.port, share: parts.share, path: path
                    )
                    result.items.append(AppleLibraryItem(
                        sourceID: source.id, name: entry.name, url: mediaURL,
                        relativePath: path, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt
                    ))
                }
            }
            if result.items.count != previousCount { await onProgress?(result.items) }
        }
        return result
    }
}
