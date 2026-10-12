import Foundation
import CryptoKit

/// Pure, testable policies for the artwork disk cache.
struct AppleArtworkDiskCachePolicy {
    static let version = "Artwork-v1"
    static let maximumBytes = 512 * 1024 * 1024

    static func fileName(for url: URL, variant: String) -> String {
        let input = url.absoluteString.data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: input)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(variant).bin"
    }

    static func evictionOrder(_ entries: [(name: String, bytes: Int, modified: Date)], limit: Int) -> [String] {
        var currentTotal = entries.map { $0.bytes }.reduce(0, +)
        guard currentTotal > limit else { return [] }

        let sorted = entries.sorted { $0.modified < $1.modified }
        var toEvict: [String] = []

        for entry in sorted {
            toEvict.append(entry.name)
            currentTotal -= entry.bytes
            if currentTotal <= limit {
                break
            }
        }
        return toEvict
    }
}

/// A bounded, persistent cache for artwork (posters, backdrops, logos).
actor AppleArtworkDiskCache {
    static let shared: AppleArtworkDiskCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("OpenStream", isDirectory: true).appendingPathComponent(AppleArtworkDiskCachePolicy.version, isDirectory: true)
        return AppleArtworkDiskCache(directory: directory)
    }()

    private let directory: URL
    private let fileManager = FileManager.default
    private var hasTrimmed = false

    init(directory: URL) {
        self.directory = directory
    }

    func data(for url: URL, variant: String) -> Data? {
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        // Touch the modification date so eviction is LRU.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return data
    }

    func contains(url: URL, variant: String) -> Bool {
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    func store(_ data: Data, for url: URL, variant: String) {
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic write
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore errors as requested
        }

        if !hasTrimmed {
            hasTrimmed = true
            Task.detached(priority: .background) {
                await self.trimIfNeeded()
            }
        }
    }

    func trimIfNeeded() {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        var entries: [(name: String, bytes: Int, modified: Date)] = []
        for url in urls {
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = attrs.fileSize,
                  let modified = attrs.contentModificationDate else { continue }
            entries.append((name: url.lastPathComponent, bytes: size, modified: modified))
        }

        let toEvict = AppleArtworkDiskCachePolicy.evictionOrder(entries, limit: AppleArtworkDiskCachePolicy.maximumBytes)
        for name in toEvict {
            let fileURL = directory.appendingPathComponent(name, isDirectory: false)
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
