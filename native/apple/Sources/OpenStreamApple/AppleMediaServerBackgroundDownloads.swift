import Foundation
import CryptoKit
import Security

/// One stable session, with non-secret job metadata kept across app relaunches.
/// URLSession owns authenticated requests and its resume data in the app sandbox.
@MainActor
public final class AppleMediaServerBackgroundDownloads: NSObject {
    public static let shared = AppleMediaServerBackgroundDownloads()
    public static let identifier = "com.orgista.openstream.media-server-downloads"

    enum Event: Sendable {
        case progress(Int64, Int64?)
        case paused
        case completed(AppleOfflineRecord)
        case failed
    }
    struct Job: Codable {
        let id: UUID
        let mediaID: String
        let title: String
        let subtitle: String?
        let artworkURL: URL?
        var isPaused = false
    }
    private var jobs: [UUID: Job] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var observers: [UUID: @MainActor (Event) -> Void] = [:]
    private var paused: Set<UUID> = []
    private var finished: Set<UUID> = []
    private var resumeData: [UUID: Data] = [:]
    private var completion: (@MainActor () -> Void)?
    private var processing = 0
    private var eventsFinished = false
    private let store = AppleOfflineMediaStore()
    private let directory = AppleStorageLocation.applicationSupport
        .appendingPathComponent("OpenStream/BackgroundDownloads", isDirectory: true)

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        #if os(iOS) || os(tvOS) || os(visionOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    private override init() {
        super.init()
        // Exclude the directory too: old resume files and future sidecars must not enter backups.
        try? AppleDownloadResumePersistence.protect(directory: directory)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "resume" {
                // Remove an unsealable legacy file rather than leave credentials in plaintext.
                if let data = try? Data(contentsOf: file), !AppleDownloadResumePersistence.isSealed(data),
                   (try? AppleDownloadResumePersistence.read(file)) == nil { try? FileManager.default.removeItem(at: file) }
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("jobs.json")),
           let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            paused = Set(saved.filter(\.isPaused).map(\.id))
            save() // Rewrite legacy artwork URLs without their tokens.
        }
    }

    public func activate() {
        session.getAllTasks { [weak self] existing in
            Task { @MainActor in
                guard let self else { return }
                for task in existing {
                    guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
                          self.jobs[id] != nil, let download = task as? URLSessionDownloadTask else { continue }
                    self.tasks[id] = download
                }
                for job in self.jobs.values where self.tasks[job.id] == nil {
                    if let data = try? AppleDownloadResumePersistence.read(self.resumeURL(job.id)) {
                        self.resumeData[job.id] = data
                        if !job.isPaused { self.resume(job.id) }
                    }
                }
            }
        }
    }

    public func handleEvents(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard identifier == Self.identifier else { completion(); return }
        self.completion = completion
        eventsFinished = false
        activate()
    }

    func start(request: AppleOfflineDownloadCoordinator.Request, plan: AppleOfflineDownloadPlan,
               observer: @escaping @MainActor (Event) -> Void) -> UUID {
        if let existing = jobs.values.first(where: { $0.mediaID == request.mediaID }) {
            observers[existing.id] = observer
            if paused.contains(existing.id) { observer(.paused) }
            return existing.id
        }
        let id = UUID()
        jobs[id] = Job(id: id, mediaID: request.mediaID, title: request.itemTitle,
                       subtitle: request.subtitle, artworkURL: request.artworkURL)
        observers[id] = observer
        save()
        var networkRequest = URLRequest(url: plan.sourceURL)
        for (key, value) in plan.requestHeaders { networkRequest.setValue(value, forHTTPHeaderField: key) }
        let task = session.downloadTask(with: networkRequest)
        task.taskDescription = id.uuidString
        tasks[id] = task
        task.resume()
        return id
    }

    func pause(_ id: UUID) {
        guard let task = tasks[id] else { return }
        paused.insert(id)
        jobs[id]?.isPaused = true
        save()
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self, self.jobs[id] != nil else { return }
                self.resumeData[id] = data
                if let data { try? AppleDownloadResumePersistence.write(data, to: self.resumeURL(id)) }
                self.observers[id]?(.paused)
            }
        })
    }

    func resume(_ id: UUID) {
        guard let data = resumeData[id] ?? (try? AppleDownloadResumePersistence.read(resumeURL(id))) else {
            observers[id]?(.failed)
            remove(id)
            return
        }
        paused.remove(id)
        jobs[id]?.isPaused = false
        save()
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = id.uuidString
        tasks[id] = task
        task.resume()
    }

    func cancel(mediaIDs: Set<String>) {
        let ids = jobs.values.filter { mediaIDs.contains($0.mediaID) }.map(\.id)
        for id in ids { cancel(id) }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        remove(id)
    }

    private func resumeURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".resume") }
    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? AppleCachedCredentialPolicy.metadata(JSONEncoder().encode(Array(jobs.values))) {
            // Job URLs carry the server token (api_key / X-Plex-Token); keep them out of device backups.
            var url = directory.appendingPathComponent("jobs.json")
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
    private func remove(_ id: UUID) {
        jobs[id] = nil
        tasks[id] = nil
        observers[id] = nil
        resumeData[id] = nil
        paused.remove(id)
        finished.remove(id)
        try? FileManager.default.removeItem(at: resumeURL(id))
        save()
    }
    private func finishEventsIfReady() {
        guard eventsFinished, processing == 0 else { return }
        let handler = completion
        completion = nil
        handler?()
    }
}

extension AppleMediaServerBackgroundDownloads: URLSessionDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        // This move must happen before returning: URLSession immediately removes location.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".media")
        do { try FileManager.default.moveItem(at: location, to: staging) }
        catch {
            Task { @MainActor [weak self] in self?.observers[id]?(.failed); self?.remove(id) }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let job = self.jobs[id] else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            self.finished.insert(id)
            self.processing += 1
            defer {
                try? FileManager.default.removeItem(at: staging)
                self.processing -= 1
                self.remove(id)
                self.finishEventsIfReady()
            }
            do {
                guard let response, (200..<300).contains(response.statusCode) else {
                    throw AppleOfflineStoreError.invalidRemoteResponse
                }
                let record = try await self.store.makeAvailable(mediaID: job.mediaID, sourceURL: staging,
                    title: job.title, subtitle: job.subtitle, artworkURL: job.artworkURL)
                guard self.jobs[id] != nil else {
                    try? await self.store.remove(mediaID: job.mediaID)
                    return
                }
                self.observers[id]?(.completed(record))
            } catch { self.observers[id]?(.failed) }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                      totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor [weak self] in
            self?.observers[id]?(.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self, self.jobs[id] != nil, !self.paused.contains(id), !self.finished.contains(id), failed else { return }
            if let data {
                self.resumeData[id] = data
                try? AppleDownloadResumePersistence.write(data, to: self.resumeURL(id))
                self.paused.insert(id)
                self.jobs[id]?.isPaused = true
                self.save()
                self.observers[id]?(.paused)
            } else {
                self.observers[id]?(.failed)
                self.remove(id)
            }
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.eventsFinished = true
            self?.finishEventsIfReady()
        }
    }
}


extension AppleMediaServerBackgroundDownloads.Job {
    private enum CodingKeys: String, CodingKey { case id, mediaID, title, subtitle, artworkURL, isPaused }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        mediaID = try values.decode(String.self, forKey: .mediaID)
        title = try values.decode(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }
}

/// Secondary metadata never retains an authenticated URL. Live objects keep the
/// original URLs; a network refresh restores their artwork after a cold launch.
enum AppleCachedCredentialPolicy {
    static func artwork(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let secretNames: Set<String> = ["api_key", "apikey", "x-plex-token", "token", "access_token", "auth", "authorization", "username", "password", "key"]
        if parts?.queryItems?.contains(where: { secretNames.contains($0.name.lowercased()) }) == true { return nil }
        let path = url.path.lowercased().split(separator: "/")
        if ["live", "movie", "series"].contains(path.first.map(String.init) ?? ""), path.count >= 4 { return nil }
        #if OPENSTREAM_ADDONS
        if path.dropLast().contains(where: { AppleAddonURLSecretPolicy.isConfigurationSegment(String($0)) }) { return nil }
        #endif
        return url
    }

    static func metadata(_ data: Data) throws -> Data {
        func scrub(_ value: Any) -> Any {
            if let fields = value as? [String: Any] { return fields.mapValues(scrub) }
            if let values = value as? [Any] { return values.map(scrub) }
            if let text = value as? String, let url = URL(string: text),
               ["https", "http", "smb"].contains(url.scheme?.lowercased() ?? ""), artwork(url) == nil { return NSNull() }
            return value
        }
        return try JSONSerialization.data(withJSONObject: scrub(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys])
    }
}

/// URLSession resume data contains archived requests (including auth headers).
/// It cannot be redacted and remain resumable, so persist only authenticated
/// ciphertext with an AfterFirstUnlockThisDeviceOnly, non-syncing Keychain key.
enum AppleDownloadResumePersistence {
    static let service = "com.orgista.openstream.download-resume.device"
    private static let prefix = Data("OpenStreamResume1".utf8)

    static func isSealed(_ data: Data) -> Bool { data.starts(with: prefix) }

    static func protect(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    static func write(_ data: Data, to url: URL, key: Data? = nil) throws {
        try protect(directory: url.deletingLastPathComponent())
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: try key ?? deviceKey()))
        guard let combined = sealed.combined else { throw AppleKeychainStoreError.invalidData }
        try (prefix + combined).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func read(_ url: URL, key: Data? = nil) throws -> Data {
        let data = try Data(contentsOf: url)
        if data.starts(with: prefix) {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(prefix.count))
            return try AES.GCM.open(box, using: SymmetricKey(data: try key ?? deviceKey()))
        }
        // Only URLSession's plist format qualifies for legacy migration.
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        try write(data, to: url, key: key)
        return data
    }

    private static func deviceKey() throws -> Data {
        if AppleKeychainStore.isBypassedForReview { throw AppleKeychainStoreError.invalidData }
        if let memory = AppleKeychainStore.testMemory {
            if let value = memory.value(service: service, account: "key"), let data = Data(base64Encoded: value) { return data }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            memory.set(key.base64EncodedString(), service: service, account: "key")
            return key
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "key",
            kSecAttrSynchronizable as String: false]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw AppleKeychainStoreError.unexpectedStatus(status) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw AppleKeychainStoreError.unexpectedStatus(added) }
        return key
    }
}
