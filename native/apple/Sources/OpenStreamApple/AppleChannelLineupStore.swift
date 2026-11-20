import Foundation
import Synchronization
import UniformTypeIdentifiers

public extension UTType {
    static let openStreamLineup = UTType(exportedAs: "com.orgista.openstream.lineup", conformingTo: .json)
}

public final class AppleChannelLineupStore: Sendable {
    public static let shared = AppleChannelLineupStore()
    public static let didChange = Notification.Name("openstream.lineup.changed")

    private struct State {
        var file: AppleChannelLineupFile?
        var data: Data?
        var updatedAt: Date?
        /// Grows with every change to `file`.
        var version: UInt64 = 0
    }

    private let directory: URL
    private let state: Mutex<State>
    private let latestCloudRevision: @Sendable () -> Date?
    private let setModificationDate: @Sendable (Date, URL) throws -> Void

    public init(directory: URL = AppleChannelLineupStore.defaultDirectory,
                latestCloudRevision: @escaping @Sendable () -> Date? = {
                    guard let data = NSUbiquitousKeyValueStore.default.data(forKey: "openstream.configuration.v1"),
                          let snapshot = try? JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data),
                          snapshot.lineup != nil else { return nil }
                    return snapshot.lineupUpdatedAt ?? snapshot.savedAt
                },
                setModificationDate: @escaping @Sendable (Date, URL) throws -> Void = { date, url in
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }) {
        self.directory = directory
        self.latestCloudRevision = latestCloudRevision
        self.setModificationDate = setModificationDate
        let url = directory.appendingPathComponent("current.oslineup")
        let data = try? Data(contentsOf: url)
        let file = data.flatMap { try? AppleChannelLineupFile.decode($0) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        state = Mutex(State(file: file, data: file == nil ? nil : data, updatedAt: file == nil ? nil : modified))
    }

    /// tvOS refuses writes outside Caches, so the Apple TV keeps its copy there; iCloud sync
    /// and backups carry the lineup, so a purged cache comes back on the next read.
    static let relativePath = {
        #if os(tvOS)
        "Library/Caches/Lineups"
        #else
        "Library/Application Support/Lineups"
        #endif
    }()

    public static var defaultDirectory: URL {
        let manager = FileManager.default
        return manager.containerURL(forSecurityApplicationGroupIdentifier: AppleTopShelfSnapshotWriter.appGroup)
            .map { $0.appendingPathComponent(relativePath, isDirectory: true) }
            ?? fallbackDirectory
    }

    static var fallbackDirectory: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("OpenStream", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    public var current: AppleChannelLineupFile? { state.withLock { $0.file } }
    public var data: Data? { state.withLock { $0.data } }
    var configuration: (data: Data?, updatedAt: Date?) { state.withLock { ($0.data, $0.updatedAt) } }
    var version: UInt64 { state.withLock { $0.version } }
    /// `current` and `version` read together.
    var versionedCurrent: (file: AppleChannelLineupFile?, version: UInt64) { state.withLock { ($0.file, $0.version) } }

    func discardAfterReset() {
        state.withLock { $0 = State(file: nil, data: nil, version: $0.version &+ 1) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Local imports are new edits; received copies retain their originating revision.
    public func importData(_ data: Data, updatedAt: Date? = nil) throws {
        let file = try AppleChannelLineupFile.decode(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(file)
        guard encoded.count <= AppleChannelLineupFile.maximumBytes else { throw AppleChannelLineupError.tooLarge }
        let cloudRevision = updatedAt == nil ? latestCloudRevision() : nil
        let changed = try state.withLock { state in
            let url = directory.appendingPathComponent("current.oslineup")
            let newerRevision = updatedAt.map { $0 > (state.updatedAt ?? .distantPast) } ?? true
            guard state.file != file || !FileManager.default.fileExists(atPath: url.path) || newerRevision else { return false }
            // A settings edit can carry an older lineup. Only its own revision decides replacement.
            if state.file != nil, state.file != file, let updatedAt, let previous = state.updatedAt,
               updatedAt < previous { return false }
            let revision = updatedAt.map { state.file == file ? max(state.updatedAt ?? $0, $0) : $0 }
                ?? AppleConfigurationSyncPolicy.editStamp(after: [state.updatedAt, cloudRevision].compactMap { $0 }.max())
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoded.write(to: url, options: .atomic)
            } catch { throw AppleChannelLineupError.couldNotSave }
            // The atomic write has committed; metadata failure must not leave memory on the old file.
            do { try setModificationDate(revision, url) }
            catch { appleTrace("lineup import: could not preserve revision metadata") }
            state = State(file: file, data: encoded, updatedAt: revision, version: state.version &+ 1)
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    public func importFile(_ url: URL) throws {
        let access = AppleSecurityScopedAccess(url: url)
        defer { withExtendedLifetime(access) {} }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= AppleChannelLineupFile.maximumBytes else { throw AppleChannelLineupError.tooLarge }
        try importData(Data(contentsOf: url))
    }

    public func importURL(_ url: URL) async throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw AppleChannelLineupError.couldNotDownload }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await AppleBoundedHTTPDataLoader.load(request,
                maximumBytes: AppleChannelLineupFile.maximumBytes, redirectPolicy: .secureHTTPOnly)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw AppleChannelLineupError.couldNotDownload
            }
            try Task.checkCancellation()
            try importData(data)
        } catch AppleBoundedHTTPError.responseTooLarge { throw AppleChannelLineupError.tooLarge }
        catch let error as AppleChannelLineupError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw AppleChannelLineupError.couldNotDownload
        }
    }
}
