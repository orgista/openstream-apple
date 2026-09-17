import AVFoundation
import Foundation

public struct AppleOfflineRecord: Identifiable, Codable, Equatable, Sendable {
    public let mediaID: String
    public let localURL: URL
    public let sourceExtension: String
    /// Container detected from the downloaded bytes, independent of the URL extension.
    public let container: String
    public let storedAt: Date
    public let title: String?
    public let subtitle: String?
    public let artworkURL: URL?
    public var id: String { mediaID }

    public init(
        mediaID: String,
        localURL: URL,
        sourceExtension: String,
        container: String = "unknown",
        storedAt: Date = .now,
        title: String? = nil,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) {
        self.mediaID = mediaID
        self.localURL = localURL
        self.sourceExtension = sourceExtension
        self.container = container
        self.storedAt = storedAt
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = cleanTitle.isEmpty ? nil : String(cleanTitle.prefix(200))
        self.subtitle = cleanSubtitle.isEmpty ? nil : String(cleanSubtitle.prefix(200))
        self.artworkURL = artworkURL
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID, localURL, sourceExtension, container, storedAt, title, subtitle, artworkURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try values.decode(String.self, forKey: .mediaID)
        localURL = try values.decode(URL.self, forKey: .localURL)
        sourceExtension = try values.decode(String.self, forKey: .sourceExtension)
        container = try values.decodeIfPresent(String.self, forKey: .container) ?? "unknown"
        storedAt = try values.decode(Date.self, forKey: .storedAt)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
    }
}

public enum AppleOfflineStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyMediaID
    case adaptiveStreamRequiresAssetDownload
    case adaptiveStreamHeadersUnsupported
    case transientGatewayStream
    case uncontainedSourceFileURL
    case sourceFileNotFound
    case unsupportedRemoteScheme
    case invalidRemoteResponse
    case downloadRequestFailed(Int)
    case emptyDownloadedFile

    public var errorDescription: String? {
        switch self {
        case .emptyMediaID: "This item does not have a stable offline identifier."
        case .adaptiveStreamRequiresAssetDownload:
            "Adaptive HLS downloads aren’t available on this device."
        case .adaptiveStreamHeadersUnsupported:
            "This adaptive stream requires request headers that Apple’s offline downloader can’t safely persist."
        case .transientGatewayStream:
            "A temporary transcoded stream cannot be kept offline. Download the original file instead."
        case .uncontainedSourceFileURL: "The selected file is outside an approved app or Files location."
        case .sourceFileNotFound: "The source file is no longer available."
        case .unsupportedRemoteScheme: "Offline downloads require an HTTP or HTTPS media URL."
        case .invalidRemoteResponse: "The media server returned an invalid download response."
        case .downloadRequestFailed(let status): "The media server rejected the download with HTTP \(status)."
        case .emptyDownloadedFile: "The media server returned an empty download."
        }
    }
}

struct AppleOfflineDownloadPlan: Equatable, Sendable {
    let sourceURL: URL
    let requestHeaders: [String: String]
    let protectedCapabilityToRevoke: URL?
}

enum AppleOfflineDownloadPolicy {
    static func plan(for resolved: AppleResolvedStremioPlayback) -> AppleOfflineDownloadPlan {
        if case .direct = resolved.preparedPlayback.route,
           resolved.preparedPlayback.url != resolved.stream.sourceURL {
            return AppleOfflineDownloadPlan(
                sourceURL: resolved.preparedPlayback.url,
                requestHeaders: [:],
                protectedCapabilityToRevoke: resolved.preparedPlayback.url
            )
        }
        return AppleOfflineDownloadPlan(
            sourceURL: resolved.stream.sourceURL,
            requestHeaders: resolved.stream.requestHeaders,
            protectedCapabilityToRevoke: nil
        )
    }
}

enum AppleOfflineActionPolicy {
    static func isAvailable(
        sourceKind: AppleSourceKind,
        itemType: String,
        indexedKind: AppleMediaKind?,
        hasLiveAvailability: Bool
    ) -> Bool {
        guard sourceKind != .liveTV,
              indexedKind != .channel,
              !hasLiveAvailability else {
            return false
        }

        let normalizedType = itemType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)
        // Offline storage is an on-demand feature. Use an allow-list so a
        // provider-specific live type such as `linear`, `event`, or `sports`
        // cannot accidentally regain Download through a catalog or Search.
        return ["movie", "series"].contains(normalizedType)
    }
}

/// App-private device-storage persistence for Apple platforms. Progressive
/// files use URLSession. On supported platforms, HLS uses
/// AVAssetDownloadURLSession so the complete stream is persisted rather than
/// saving only the playlist; the download action is intentionally hidden on
/// tvOS and for live channels.
public actor AppleOfflineMediaStore {
    public typealias Downloader = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    public typealias HLSDownloader = @Sendable (URL, String) async throws -> URL

    private let rootDirectory: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let allowedDirectories: [URL]
    private let downloader: Downloader
    private let hlsDownloader: HLSDownloader

    public init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        allowedDirectories: [URL]? = nil,
        downloader: @escaping Downloader = { request in
            try await URLSession.shared.download(for: request)
        },
        hlsDownloader: HLSDownloader? = nil
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
        self.hlsDownloader = hlsDownloader ?? AppleOfflineMediaStore.liveHLSDownloader
        let applicationSupport = rootDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "OpenStream/Offline", directoryHint: .isDirectory)
        self.rootDirectory = applicationSupport
        self.manifestURL = applicationSupport.appending(path: "manifest.json")

        if let allowedDirectories {
            self.allowedDirectories = allowedDirectories
        } else {
            var defaults: [URL] = [
                applicationSupport,
                applicationSupport.deletingLastPathComponent(),
                fileManager.temporaryDirectory,
                URL(fileURLWithPath: NSTemporaryDirectory()),
            ]
            for searchPath in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory, .applicationSupportDirectory, .downloadsDirectory] {
                defaults.append(contentsOf: fileManager.urls(for: searchPath, in: .userDomainMask))
            }
            if let customRoot = rootDirectory {
                defaults.append(customRoot)
                defaults.append(customRoot.deletingLastPathComponent())
            }
            self.allowedDirectories = defaults
        }
    }

    public func record(for mediaID: String) -> AppleOfflineRecord? {
        guard let record = loadManifest()[mediaID], fileManager.fileExists(atPath: record.localURL.path) else {
            return nil
        }
        return record
    }

    public func allRecords() -> [AppleOfflineRecord] {
        loadManifest().values
            .filter { fileManager.fileExists(atPath: $0.localURL.path) }
            .sorted { $0.storedAt > $1.storedAt }
    }

    public func isPathContained(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !canonicalPath.isEmpty, canonicalPath != "/" else { return false }

        for allowed in allowedDirectories {
            let allowedPath = allowed.standardizedFileURL.resolvingSymlinksInPath().path
            guard !allowedPath.isEmpty, allowedPath != "/" else { continue }
            if canonicalPath == allowedPath {
                return true
            }
            let prefix = allowedPath.hasSuffix("/") ? allowedPath : allowedPath + "/"
            if canonicalPath.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func makeAvailable(
        mediaID: String,
        sourceURL: URL,
        requestHeaders: [String: String] = [:],
        title: String? = nil,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) async throws -> AppleOfflineRecord {
        guard !mediaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleOfflineStoreError.emptyMediaID
        }
        if Self.isHLSURL(sourceURL) {
            guard requestHeaders.isEmpty else {
                throw AppleOfflineStoreError.adaptiveStreamHeadersUnsupported
            }
            return try await makeHLSAvailable(
                mediaID: mediaID,
                sourceURL: sourceURL,
                title: title,
                subtitle: subtitle,
                artworkURL: artworkURL
            )
        }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let manifest = loadManifest()
        let existingRecord = manifest[mediaID]
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "media" : sourceURL.pathExtension.lowercased()
        let destination = rootDirectory.appending(path: "\(stableIdentifier(mediaID)).\(sourceExtension)")
        let stagingURL = rootDirectory.appending(
            path: ".\(stableIdentifier(mediaID))-\(UUID().uuidString).partial"
        )
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        if sourceURL.isFileURL {
            guard isPathContained(sourceURL) else {
                throw AppleOfflineStoreError.uncontainedSourceFileURL
            }
            let canonicalSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonicalSource.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw AppleOfflineStoreError.sourceFileNotFound
            }
            try fileManager.copyItem(at: canonicalSource, to: stagingURL)
        } else {
            guard let scheme = sourceURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw AppleOfflineStoreError.unsupportedRemoteScheme
            }
            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = 60
            for (name, value) in Self.safeRequestHeaders(requestHeaders) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (temporaryURL, response) = try await downloader(request)
            defer {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppleOfflineStoreError.invalidRemoteResponse
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw AppleOfflineStoreError.downloadRequestFailed(httpResponse.statusCode)
            }
            guard temporaryURL.isFileURL,
                  fileManager.fileExists(atPath: temporaryURL.path) else {
                throw AppleOfflineStoreError.invalidRemoteResponse
            }
            if Self.isHLSManifest(response: httpResponse, fileURL: temporaryURL) {
                guard requestHeaders.isEmpty else {
                    throw AppleOfflineStoreError.adaptiveStreamHeadersUnsupported
                }
                return try await makeHLSAvailable(
                    mediaID: mediaID,
                    sourceURL: sourceURL,
                    title: title,
                    subtitle: subtitle,
                    artworkURL: artworkURL
                )
            }
            try fileManager.moveItem(at: temporaryURL, to: stagingURL)
        }

        guard fileByteCount(at: stagingURL) > 0 else {
            throw AppleOfflineStoreError.emptyDownloadedFile
        }
        let container = try Self.sniffContainer(at: stagingURL, fallback: sourceExtension)
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destination)
        }

        var updatedManifest = manifest
        let record = AppleOfflineRecord(
            mediaID: mediaID,
            localURL: destination,
            sourceExtension: sourceExtension,
            container: container,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL
        )
        updatedManifest[mediaID] = record
        try saveManifest(updatedManifest)
        if let existingRecord,
           existingRecord.localURL != destination,
           fileManager.fileExists(atPath: existingRecord.localURL.path) {
            try? fileManager.removeItem(at: existingRecord.localURL)
        }
        return record
    }

    public func remove(mediaID: String) throws {
        var manifest = loadManifest()
        if let record = manifest.removeValue(forKey: mediaID), fileManager.fileExists(atPath: record.localURL.path) {
            try fileManager.removeItem(at: record.localURL)
        }
        try saveManifest(manifest)
    }

    private func makeHLSAvailable(
        mediaID: String,
        sourceURL: URL,
        title: String?,
        subtitle: String?,
        artworkURL: URL?
    ) async throws -> AppleOfflineRecord {
        #if os(tvOS)
        throw AppleOfflineStoreError.adaptiveStreamRequiresAssetDownload
        #else
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let downloadedURL = try await hlsDownloader(sourceURL, mediaID)
        guard downloadedURL.isFileURL,
              fileManager.fileExists(atPath: downloadedURL.path) else {
            throw AppleOfflineStoreError.invalidRemoteResponse
        }
        var manifest = loadManifest()
        let existingRecord = manifest[mediaID]
        let record = AppleOfflineRecord(
            mediaID: mediaID,
            localURL: downloadedURL,
            sourceExtension: "movpkg",
            container: "hls",
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL
        )
        manifest[mediaID] = record
        try saveManifest(manifest)
        if let existingRecord,
           existingRecord.localURL != downloadedURL,
           fileManager.fileExists(atPath: existingRecord.localURL.path) {
            try? fileManager.removeItem(at: existingRecord.localURL)
        }
        return record
        #endif
    }

    private func loadManifest() -> [String: AppleOfflineRecord] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AppleOfflineRecord].self, from: data)) ?? [:]
    }

    private func saveManifest(_ manifest: [String: AppleOfflineRecord]) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func fileByteCount(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            return enumerator.compactMap { $0 as? URL }.reduce(0) { total, child in
                let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return total }
                return total + Int64(values?.fileSize ?? 0)
            }
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "m3u8" || fileExtension == "m3u"
    }

    private static func isHLSManifest(response: HTTPURLResponse, fileURL: URL) -> Bool {
        let hlsMIMETypes = Set([
            "application/vnd.apple.mpegurl",
            "application/x-mpegurl",
            "audio/mpegurl",
            "audio/x-mpegurl",
        ])
        if let mimeType = response.mimeType?.lowercased(), hlsMIMETypes.contains(mimeType) {
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 256) else { return false }
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\u{FEFF}")
            ))
        return text.hasPrefix("#EXTM3U")
    }

    /// Detects the actual media container so a misleading URL extension cannot
    /// send MKV/TS through AVFoundation's native offline export path.
    public static func sniffContainer(data: Data, fallback: String = "unknown") -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 4, bytes.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) {
            return "mkv"
        }
        if bytes.count >= 8, bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) {
            return "mp4"
        }
        if bytes.count >= 188, stride(from: 0, through: bytes.count - 188, by: 188).allSatisfy({ bytes[$0] == 0x47 }) {
            return "ts"
        }
        let normalized = fallback.lowercased()
        if ["mkv", "matroska", "webm"].contains(normalized) { return normalized == "webm" ? "webm" : "mkv" }
        if ["mp4", "m4v", "mov"].contains(normalized) { return normalized == "mov" ? "mov" : "mp4" }
        if normalized == "ts" || normalized == "mpegts" { return "ts" }
        return normalized.isEmpty ? "unknown" : normalized
    }

    private static func sniffContainer(at url: URL, fallback: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 376) ?? Data()
        return sniffContainer(data: prefix, fallback: fallback)
    }

    private static func liveHLSDownloader(_ url: URL, title: String) async throws -> URL {
        #if os(tvOS)
        throw AppleOfflineStoreError.adaptiveStreamRequiresAssetDownload
        #else
        try await AppleHLSAssetDownloader.download(url: url, title: title)
        #endif
    }

    private static func safeRequestHeaders(_ values: [String: String]) -> [String: String] {
        let allowed = Set(["user-agent", "referer", "authorization"])
        return Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(cleanName.lowercased()),
                  cleanName.count <= 64,
                  cleanValue.count <= 2_048,
                  !cleanValue.contains("\r"),
                  !cleanValue.contains("\n") else { return nil }
            return (cleanName, cleanValue)
        })
    }
}

#if !os(tvOS)
private final class AppleHLSAssetDownloader: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var downloadedURL: URL?
    private var session: AVAssetDownloadURLSession?

    static func download(url: URL, title: String) async throws -> URL {
        let delegate = AppleHLSAssetDownloader()
        return try await withCheckedThrowingContinuation { continuation in
            delegate.start(url: url, title: title, continuation: continuation)
        }
    }

    private func start(
        url: URL,
        title: String,
        continuation: CheckedContinuation<URL, any Error>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.orgista.openstream.offline.\(UUID().uuidString)"
        )
        configuration.isDiscretionary = false
        let session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
        self.session = session
        let asset = AVURLAsset(url: url)
        let configurationForAsset = AVAssetDownloadConfiguration(asset: asset, title: title)
        session.makeAssetDownloadTask(downloadConfiguration: configurationForAsset).resume()
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        lock.lock()
        downloadedURL = location
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let continuation = self.continuation
        let downloadedURL = self.downloadedURL
        self.continuation = nil
        self.downloadedURL = nil
        lock.unlock()

        self.session?.finishTasksAndInvalidate()
        self.session = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let downloadedURL {
            continuation?.resume(returning: downloadedURL)
        } else {
            continuation?.resume(throwing: AppleOfflineStoreError.invalidRemoteResponse)
        }
    }
}
#endif
