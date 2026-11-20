import Foundation
import Synchronization

/// Playback JSON retains its existing schema. Defaults are retired only after
/// both file copies have been written atomically and read back byte-for-byte.
@MainActor
final class ApplePlaybackBlobStorage {
    private static var standardStorage: ApplePlaybackBlobStorage?
    private let defaults: UserDefaults
    private let directory: URL?
    private var cached: [String: Data] = [:]
    private var readKeys: Set<String> = []
    /// Defaults-backed reads (Apple TV), kept until any default changes.
    private var defaultsCache: [String: Data?] = [:]
    private var defaultsCacheGeneration = -1
    private var writes = 0

    /// Changes whenever a value read through this storage may have: on Apple
    /// TV with any change to the defaults, elsewhere with this storage's own
    /// writes (its file reads are cached the same way).
    var revision: Int { directory == nil ? AppleDefaultsChangeCount.current : writes }

    static func storage(defaults: UserDefaults, directory: URL? = nil) -> ApplePlaybackBlobStorage {
        if let directory { return .init(defaults: defaults, directory: directory) }
        guard defaults === UserDefaults.standard else { return .init(defaults: defaults, directory: nil) }
        if let standardStorage { return standardStorage }
        #if os(tvOS)
        // Apple TV may purge everything but defaults, the keychain and iCloud
        // (AppleStorageLocation). Moving playback history into a file there and
        // retiring the defaults copy could lose it, so tvOS stays on defaults.
        let tvStorage = ApplePlaybackBlobStorage(defaults: defaults, directory: nil)
        standardStorage = tvStorage
        return tvStorage
        #else
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppleTopShelfSnapshotWriter.appGroup)
        let root = group.flatMap { root in
            FileManager.default.isWritableFile(atPath: root.path)
                ? root.appendingPathComponent("PlaybackState-v1", isDirectory: true) : nil
        }
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        standardStorage = storage
        return storage
        #endif
    }

    static func discardAfterReset() {
        // Existing stores may still reference this shared object during reset.
        // Invalidate it in place so old and newly created stores stay coherent.
        standardStorage?.cached.removeAll()
        standardStorage?.readKeys.removeAll()
        standardStorage?.defaultsCache.removeAll()
        standardStorage?.writes += 1
    }

    init(defaults: UserDefaults, directory: URL?) {
        self.defaults = defaults
        self.directory = directory
        if directory == nil { _ = AppleDefaultsChangeCount.current }
    }

    func fileURL(forKey key: String) -> URL {
        // Called only with a configured directory; callers use defaults otherwise.
        (directory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(ApplePlaybackIdentity.digest(for: key) + ".json")
    }

    private func fallbackKey(_ key: String) -> String {
        "openstream.playback.fileFallback." + ApplePlaybackIdentity.digest(for: key)
    }

    func data(forKey key: String) -> Data? {
        guard directory != nil else { return defaultsData(forKey: key) }
        // Cache first: removing defaults can synchronously invalidate SwiftUI,
        // and argument/registration values cannot be removed at all.
        if readKeys.contains(key) { return cached[key] }
        let url = fileURL(forKey: key)
        let legacy = defaults.data(forKey: key)
        let file = validData(at: url) ?? validData(at: url.appendingPathExtension("backup"))
        let data: Data?
        if defaults.bool(forKey: fallbackKey(key)), let legacy {
            // A prior failed write left defaults newer than the existing file.
            data = legacy
        } else if let file {
            data = file
        } else if let legacy {
            data = legacy
            if persist(legacy, forKey: key) {
                retireDefaults(forKey: key)
            } else {
                defaults.set(true, forKey: fallbackKey(key))
            }
        } else {
            data = nil
        }
        readKeys.insert(key)
        cached[key] = data
        return data
    }

    /// Each playback query compares every stored map against its decoded
    /// copy, and on the Apple TV each of those reads went to the defaults
    /// database and copied the blob out (~120 ms of main thread over a launch
    /// on an Apple TV 4K, 2026-10-15). Any change to any default drops the copies.
    private func defaultsData(forKey key: String) -> Data? {
        let generation = AppleDefaultsChangeCount.current
        if generation != defaultsCacheGeneration {
            defaultsCache.removeAll(keepingCapacity: true)
            defaultsCacheGeneration = generation
        }
        if let known = defaultsCache[key] { return known }
        let data = defaults.data(forKey: key)
        defaultsCache[key] = data
        return data
    }

    func set(_ data: Data?, forKey key: String) {
        guard let data else { removeObject(forKey: key); return }
        guard directory != nil else { defaults.set(data, forKey: key); return }
        if cached[key] == data && readKeys.contains(key),
           !defaults.bool(forKey: fallbackKey(key)) { return }
        writes += 1
        if persist(data, forKey: key) {
            retireDefaults(forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        } else {
            // Set the small marker first so a relaunch never prefers an older
            // file to the newly persisted fallback value.
            defaults.set(true, forKey: fallbackKey(key))
            defaults.set(data, forKey: key)
            cached[key] = data
            readKeys.insert(key)
        }
    }

    private func retireDefaults(forKey key: String) {
        if defaults.bool(forKey: fallbackKey(key)) { defaults.removeObject(forKey: fallbackKey(key)) }
        if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    }

    func removeObject(forKey key: String) {
        // Empty maps remain valid files, so an old backup cannot resurrect a cleared map.
        guard directory != nil else { defaults.removeObject(forKey: key); return }
        set(Data("{}".utf8), forKey: key)
    }

    private func validData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    private func persist(_ data: Data, forKey key: String) -> Bool {
        guard let directory else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(forKey: key)
            let backup = url.appendingPathExtension("backup")
            #if os(iOS) || os(watchOS) || os(visionOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try data.write(to: backup, options: options)
            try data.write(to: url, options: options)
            guard try Data(contentsOf: url) == data, try Data(contentsOf: backup) == data else { return false }
            cached[key] = data
            readKeys.insert(key)
            return true
        } catch {
            let failure = error as NSError
            AppleInteractionTrace.record(.failure, "Playback file write failed: \(failure.domain) code=\(failure.code)")
            return false
        }
    }
}

/// How many times this process's defaults have changed, counted from
/// `UserDefaults.didChangeNotification`, which is posted on the writing thread
/// before the write returns.
enum AppleDefaultsChangeCount {
    private static let count = Atomic<Int>(0)
    // The token is not Sendable; it is created once (a static let is lazy and
    // thread-safe) and only kept alive, never read.
    nonisolated(unsafe) private static let observer = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { _ in count.add(1, ordering: .relaxed) }

    static var current: Int {
        _ = observer
        return count.load(ordering: .relaxed)
    }
}
