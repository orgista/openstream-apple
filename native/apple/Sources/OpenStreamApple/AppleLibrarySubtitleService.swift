import Foundation

/// Owned by one playback coordinator: retries reuse the directory result,
/// while a later play sees newly added sidecars. No work happens during scans.
actor AppleLibrarySubtitleService {
    private var cache: [URL: Task<[AppleExternalSubtitleTrack], Never>] = [:]

    deinit {
        for task in cache.values { task.cancel() }
    }

    func tracks(for video: URL) async -> [AppleExternalSubtitleTrack] {
        if let cached = cache[video] { return await cached.value }
        let task = Task { await Self.discover(video) }
        cache[video] = task
        return await task.value
    }

    @concurrent private static func discover(_ video: URL) async -> [AppleExternalSubtitleTrack] {
        do {
            try Task.checkCancellation()
            if video.isFileURL {
                let files = try FileManager.default.contentsOfDirectory(
                    at: video.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
                return matching(video: video, files: files.filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                })
            }
            guard video.scheme?.lowercased() == "smb" else { return [] }
            let credentials = try await credentials(for: video)
            let client = AppleSMBClient()
            do {
                let tracks = try await AppleSMBLibraryScanner(client: client)
                    .siblingSubtitles(for: video, credentials: credentials)
                await client.closeAll()
                return tracks
            } catch {
                await client.closeAll()
                throw error
            }
        } catch { return [] } // Sidecars are optional; playback continues.
    }

    nonisolated static func matching(video: URL, files: [URL]) -> [AppleExternalSubtitleTrack] {
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        guard !stem.isEmpty else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            let subtitleStem = file.deletingPathExtension().lastPathComponent.lowercased()
            let sameFolder: Bool
            if file.isFileURL, video.isFileURL {
                sameFolder = file.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == video.deletingLastPathComponent().resolvingSymlinksInPath().path
            } else {
                sameFolder = file.scheme == video.scheme && file.host == video.host && file.port == video.port
                    && file.deletingLastPathComponent().path == video.deletingLastPathComponent().path
            }
            guard sameFolder,
                  ["srt", "vtt", "ass", "ssa"].contains(file.pathExtension.lowercased()),
                  subtitleStem.hasPrefix(stem) else { return nil }
            // Only suffix tokens describe the subtitle; "en" in the movie
            // title itself must not turn an untagged file into English.
            let tokens = subtitleStem.dropFirst(stem.count).split(separator: ".").map(String.init)
            let language = tokens.first {
                $0 != "sdh" && $0 != "forced"
                    && Locale.LanguageCode.isoLanguageCodes.contains(Locale.LanguageCode($0))
            } ?? ""
            let qualifiers = [tokens.contains("sdh") ? "SDH" : nil,
                              tokens.contains("forced") ? "Forced" : nil].compactMap { $0 }
            let base = language.isEmpty && !qualifiers.isEmpty ? "" : AppleExternalSubtitleTrack.languageName(for: language)
            let title = ([base] + qualifiers).filter { !$0.isEmpty }.joined(separator: " ")
            return AppleExternalSubtitleTrack(id: "sibling:" + file.absoluteString,
                languageCode: language, displayName: title, url: file)
        }
    }

    /// Resolve through the saved library source, never through URL credentials.
    @MainActor static func credentials(for file: URL) throws -> AppleSMBCredentials {
        let store = AppleSourceStore()
        let target = try AppleSMBEndpointPolicy.parts(from: file)
        let source = store.sources.filter {
            guard $0.kind == .nas, $0.isEnabled,
                  let root = try? AppleSMBEndpointPolicy.parts(from: $0.url) else { return false }
            return root.host.lowercased() == target.host.lowercased() && root.port == target.port
                && root.share == target.share
                && (root.path.isEmpty || target.path.hasPrefix(root.path + "/"))
        }.max { $0.url.path.count < $1.url.path.count }
        guard let source else { throw AppleLibrarySourceError.unavailable }
        return try store.networkCredentials(for: source) ?? AppleSMBCredentials(username: "", password: "")
    }

    @concurrent static func localData(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: AppleExternalSubtitleService.maximumSubtitleBytes + 1) ?? Data()
        guard data.count <= AppleExternalSubtitleService.maximumSubtitleBytes else {
            throw AppleLibrarySourceError.unavailable
        }
        try Task.checkCancellation()
        return data
    }
}
