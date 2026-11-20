import Foundation
import CryptoKit

struct AppleArtworkColour: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// Pure, testable policies for the artwork disk cache.
struct AppleArtworkDiskCachePolicy {
    static let version = "Artwork-v1"
    static let maximumBytes = 512 * 1024 * 1024

    /// A trim frees down to here, so the writes after it do not each walk the
    /// whole folder again.
    static func trimTarget(maximumBytes: Int) -> Int { maximumBytes / 8 * 7 }

    static func fileName(for url: URL, variant: String) -> String {
        let input = url.absoluteString.data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: input)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(variant).bin"
    }

    static func evictionOrder(_ entries: [(name: String, bytes: Int, modified: Date)], limit: Int) -> [String] {
        var currentTotal = entries.map { $0.bytes }.reduce(0, +)
        guard currentTotal > limit else { return [] }

        let sorted = entries.sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified }
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
    private let maximumBytes: Int
    private let fileManager = FileManager.default
    private struct Entry: Sendable {
        let bytes: Int
        var accessed: Date
    }
    private var entries: [String: Entry] = [:]
    private var indexed = false
    private var indexTask: Task<Void, Never>?
    private var removedDuringIndex: Set<String> = []
    private var totalBytes = 0
    private var trimTask: Task<Void, Never>?
    private var pendingAccesses: [String: Date] = [:]
    private var accessTask: Task<Void, Never>?
    private var accessWrite: Task<Void, Never>?
    private var failedUntil: [String: Date] = [:]
    private(set) var failureGeneration = 0
    private static let failureTTL: TimeInterval = 24 * 60 * 60

    init(directory: URL, maximumBytes: Int = AppleArtworkDiskCachePolicy.maximumBytes) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    private func startIndexIfNeeded() {
        guard !indexed, indexTask == nil else { return }
        let directory = directory
        // Directory discovery and stat calls never occupy the cache actor's executor.
        indexTask = Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
            var batch: [String: Entry] = [:]
            while let url = enumerator?.nextObject() as? URL {
                guard !Task.isCancelled else { return }
                guard url.pathExtension == "bin", let values = try? url.resourceValues(forKeys: keys),
                      let bytes = values.fileSize else { continue }
                batch[url.lastPathComponent] = Entry(bytes: bytes, accessed: values.contentModificationDate ?? .distantPast)
                if batch.count >= 128 {
                    await self.mergeIndex(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            await self.mergeIndex(batch)
            await self.finishIndex()
        }
    }

    private func mergeIndex(_ batch: [String: Entry]) {
        for (name, entry) in batch where entries[name] == nil && !removedDuringIndex.contains(name) {
            entries[name] = entry
            totalBytes += entry.bytes
        }
    }

    private func finishIndex() {
        indexed = true
        indexTask = nil
        removedDuringIndex.removeAll()
        scheduleTrimIfNeeded()
    }

    private static func decodeColour(_ data: Data) -> AppleArtworkColour? {
        guard data.count == 3 else { return nil }
        let bytes = Array(data)
        return AppleArtworkColour(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    func data(for url: URL, variant: String) -> Data? {
        startIndexIfNeeded()
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            if let entry = entries.removeValue(forKey: name) { totalBytes -= entry.bytes }
            if !indexed { removedDuringIndex.insert(name) }
            return nil
        }
        let now = Date.now
        totalBytes += data.count - (entries[name]?.bytes ?? 0)
        entries[name] = Entry(bytes: data.count, accessed: now)
        pendingAccesses[name] = now
        scheduleAccessFlush()
        return data
    }

    func colour(for url: URL) -> AppleArtworkColour? {
        data(for: url, variant: "colour").flatMap(Self.decodeColour)
    }

    func containsFailure(for url: URL, now: Date = .now) async -> Bool {
        startIndexIfNeeded()
        await indexTask?.value
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: "failure")
        let expiration: Date?
        if let cached = failedUntil[name] {
            expiration = cached
        } else {
            guard entries[name] != nil else { return false }
            expiration = data(for: url, variant: "failure")
                .flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
        }
        guard let expiration else { return false }
        guard expiration > now else {
            failedUntil[name] = nil
            try? remove(for: url, variant: "failure")
            return false
        }
        failedUntil[name] = expiration
        return true
    }

    func recordFailure(for url: URL, generation: Int, now: Date = .now, lifetime: TimeInterval? = nil) {
        guard generation == failureGeneration else { return }
        let expiration = now.addingTimeInterval(lifetime ?? Self.failureTTL)
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: "failure")
        failedUntil[name] = expiration
        if let data = try? JSONEncoder().encode(expiration) { store(data, for: url, variant: "failure") }
    }

    func clearFailures(for urls: [URL]? = nil) async {
        if let urls, urls.isEmpty { return }
        startIndexIfNeeded()
        await indexTask?.value
        failureGeneration &+= 1
        let names: Set<String>
        if let urls {
            names = Set(urls.map { AppleArtworkDiskCachePolicy.fileName(for: $0, variant: "failure") })
            for name in names { failedUntil[name] = nil }
        } else {
            names = Set(entries.keys.filter { $0.hasSuffix("-failure.bin") })
            failedUntil.removeAll()
        }
        for name in names where entries[name] != nil {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                if let entry = entries.removeValue(forKey: name) { totalBytes -= entry.bytes }
                pendingAccesses[name] = nil
            } catch {
                appleTrace("artwork failure cache could not remove an entry")
            }
        }
    }

    func storeColour(_ colour: AppleArtworkColour, for url: URL) {
        store(Data([colour.red, colour.green, colour.blue]), for: url, variant: "colour")
    }

    func contains(url: URL, variant: String) -> Bool {
        startIndexIfNeeded()
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        if entries[name] != nil { return true }
        guard !indexed, let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
              let bytes = attributes[.size] as? Int else { return false }
        entries[name] = Entry(bytes: bytes, accessed: attributes[.modificationDate] as? Date ?? .distantPast)
        totalBytes += bytes
        return true
    }

    func store(_ data: Data, for url: URL, variant: String) {
        startIndexIfNeeded()
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { return }
        removedDuringIndex.remove(name)
        pendingAccesses[name] = nil
        totalBytes += data.count - (entries[name]?.bytes ?? 0)
        entries[name] = Entry(bytes: data.count, accessed: .now)
        scheduleTrimIfNeeded()
    }

    func remove(for url: URL, variant: String) throws {
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant)
        let file = directory.appendingPathComponent(name)
        if let entry = entries.removeValue(forKey: name) { totalBytes -= entry.bytes }
        pendingAccesses[name] = nil
        if !indexed { removedDuringIndex.insert(name) }
        if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
    }

    private func scheduleAccessFlush() {
        guard accessTask == nil else { return }
        accessTask = Task(priority: .background) {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await flushPendingAccesses()
            accessTask = nil
            if !pendingAccesses.isEmpty { scheduleAccessFlush() }
        }
    }

    func flushPendingAccesses() async {
        guard !pendingAccesses.isEmpty else { await accessWrite?.value; return }
        let accesses = pendingAccesses
        pendingAccesses.removeAll(keepingCapacity: true)
        let directory = directory
        let previous = accessWrite
        let write = Task.detached(priority: .background) {
            await previous?.value
            for (name, accessed) in accesses {
                try? FileManager.default.setAttributes([.modificationDate: accessed],
                    ofItemAtPath: directory.appendingPathComponent(name).path)
            }
        }
        accessWrite = write
        await write.value
    }

    func trimIfNeeded() async {
        startIndexIfNeeded()
        await indexTask?.value
        await flushPendingAccesses()
        scheduleTrimIfNeeded()
        await trimTask?.value
    }

    private func scheduleTrimIfNeeded() {
        guard indexed, totalBytes > maximumBytes, trimTask == nil else { return }
        trimTask = Task(priority: .background) { await self.performTrim() }
    }

    private func performTrim() async {
        defer { trimTask = nil }
        guard totalBytes > maximumBytes else { return }
        let candidates = entries
        let names = AppleArtworkDiskCachePolicy.evictionOrder(candidates.map {
            (name: $0.key, bytes: $0.value.bytes, modified: $0.value.accessed)
        }, limit: AppleArtworkDiskCachePolicy.trimTarget(maximumBytes: maximumBytes))
        for name in names {
            await Task.yield()
            guard entries[name]?.accessed == candidates[name]?.accessed else { continue }
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                if let removed = entries.removeValue(forKey: name) { totalBytes -= removed.bytes }
                pendingAccesses[name] = nil
            } catch {
                // Failed removals remain in the index and the byte budget.
            }
        }
    }
}
