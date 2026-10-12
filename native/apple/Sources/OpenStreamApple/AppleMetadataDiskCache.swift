import Foundation
import CryptoKit

struct AppleMetadataDiskCachePolicy {
    static let version = "Meta-v2"
    static let freshFor: TimeInterval = 24 * 3600
    static let keepFor: TimeInterval = 14 * 24 * 3600

    static func fileName(source: String, type: String, mediaID: String) -> String {
        // The source identity is the complete request endpoint, including
        // provider configuration. Only its hash is persisted as a filename.
        let identity = [version, source, type, mediaID]
            .map { "\($0.utf8.count):\($0)" }.joined()
        let input = Data(identity.utf8)
        let hash = SHA256.hash(data: input)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    enum Freshness { case fresh, stale, expired }

    static func freshness(storedAt: Date, now: Date) -> Freshness {
        let age = now.timeIntervalSince(storedAt)
        if age < freshFor { return .fresh }
        if age < keepFor { return .stale }
        return .expired
    }
}

actor AppleMetadataDiskCache {
    static let shared: AppleMetadataDiskCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("OpenStream", isDirectory: true)
            .appendingPathComponent(AppleMetadataDiskCachePolicy.version, isDirectory: true)
        return AppleMetadataDiskCache(directory: directory)
    }()

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) {
        self.directory = directory
    }

    struct Entry: Codable {
        let storedAt: Date
        let payload: Data
    }

    func entry(source: String, type: String, mediaID: String) -> (payload: Data, freshness: AppleMetadataDiskCachePolicy.Freshness)? {
        let name = AppleMetadataDiskCachePolicy.fileName(source: source, type: type, mediaID: mediaID)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        let freshness = AppleMetadataDiskCachePolicy.freshness(storedAt: entry.storedAt, now: Date())
        if freshness == .expired {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return (payload: entry.payload, freshness: freshness)
    }

    func store(_ payload: Data, source: String, type: String, mediaID: String) {
        let name = AppleMetadataDiskCachePolicy.fileName(source: source, type: type, mediaID: mediaID)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        let entry = Entry(storedAt: Date(), payload: payload)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entry) {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Ignore errors as requested
        }
    }
}
