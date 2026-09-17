import Foundation
import Observation

public enum AppleLocalDownloadPlatform: String, Sendable {
    case iPhone
    case iPad
    case macOS
    case tvOS
    case visionOS
}

public enum AppleLocalDownloadPlatformPolicy {
    public static func isSupported(_ platform: AppleLocalDownloadPlatform) -> Bool {
        switch platform {
        case .iPhone, .iPad, .macOS:
            true
        case .tvOS, .visionOS:
            false
        }
    }

    public static var isSupportedOnCurrentPlatform: Bool {
        #if os(iOS)
        true
        #elseif os(macOS)
        true
        #else
        false
        #endif
    }
}

enum AppleOfflineDownloadFailure: Equatable, Sendable {
    case unsupportedPlatform
    case noDownloadSource
    case invalidResponse
    case invalidResume
    case httpStatus(Int)
    case timedOut
    case networkUnavailable
    case storageUnavailable
    case preparationFailed

    var message: String {
        switch self {
        case .unsupportedPlatform:
            "Local downloads are available on iPhone, iPad, and Mac."
        case .noDownloadSource:
            "No downloadable source is currently available. Try another source."
        case .invalidResponse:
            "The media server returned an invalid download response."
        case .invalidResume:
            "The saved download position could not be resumed. OpenStream will restart safely."
        case .httpStatus(let status):
            "The media server rejected the download with HTTP \(status)."
        case .timedOut:
            "The download timed out. Check the connection and retry."
        case .networkUnavailable:
            "The network is unavailable. Reconnect and retry the download."
        case .storageUnavailable:
            "OpenStream could not save the download. Check available storage and retry."
        case .preparationFailed:
            "OpenStream could not prepare this download. Try another source."
        }
    }
}

@MainActor
@Observable
final class AppleOfflineDownloadCoordinator {
    struct Request: Equatable, Sendable {
        let mediaID: String
        let itemTitle: String
        let subtitle: String?
        let artworkURL: URL?
        let destinationLabel: String
    }

    enum State: Equatable, Sendable {
        case idle
        case resolving(item: String, destination: String)
        case downloading(item: String, destination: String, received: Int64, expected: Int64?)
        case paused(item: String, destination: String, received: Int64, expected: Int64?)
        case resuming(item: String, destination: String, received: Int64, expected: Int64?)
        case completed(item: String, destination: URL, bytes: Int64, container: String)
        case failed(item: String, message: String)
        case cancelled(item: String)

        var isInProgress: Bool {
            switch self {
            case .resolving, .downloading, .resuming: true
            default: false
            }
        }

        var ownsDownload: Bool {
            switch self {
            case .resolving, .downloading, .paused, .resuming: true
            default: false
            }
        }

        var isCompleted: Bool {
            if case .completed = self { return true }
            return false
        }

        /// The case name alone, so progress updates within one phase compare equal.
        var phaseName: String {
            switch self {
            case .idle: "idle"
            case .resolving: "resolving"
            case .downloading: "downloading"
            case .paused: "paused"
            case .resuming: "resuming"
            case .completed: "completed"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }

        var container: String? {
            if case .completed(_, _, _, let container) = self { return container }
            return nil
        }
    }

    typealias PlanResolver = @MainActor () async throws -> [AppleOfflineDownloadPlan]
    typealias CapabilityRevoker = @MainActor ([URL]) async -> Void

    private(set) var state: State = .idle
    private(set) var supportsPauseResume = false
    @ObservationIgnored var stateDidChange: (@MainActor (State) -> Void)?

    @ObservationIgnored private let store: AppleOfflineMediaStore
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let temporaryDirectory: URL
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var resolver: PlanResolver?
    @ObservationIgnored private var revoker: CapabilityRevoker?
    @ObservationIgnored private var plans: [AppleOfflineDownloadPlan] = []
    @ObservationIgnored private var planIndex = 0
    @ObservationIgnored private var driver: AppleOfflineDataTaskDriver?
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var partialURL: URL?
    @ObservationIgnored private var receivedBytes: Int64 = 0
    @ObservationIgnored private var expectedBytes: Int64?
    @ObservationIgnored private var operationID = UUID()

    init(
        store: AppleOfflineMediaStore = AppleOfflineMediaStore(),
        sessionConfiguration: URLSessionConfiguration = .default,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.store = store
        self.sessionConfiguration = sessionConfiguration
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    func start(
        request: Request,
        resolvePlans: @escaping PlanResolver,
        revokeCapabilities: @escaping CapabilityRevoker = { _ in }
    ) {
        guard AppleLocalDownloadPlatformPolicy.isSupportedOnCurrentPlatform else {
            transition(.failed(item: request.itemTitle, message: AppleOfflineDownloadFailure.unsupportedPlatform.message))
            return
        }
        abandonCurrentWork(removePartial: true)
        operationID = UUID()
        self.request = request
        resolver = resolvePlans
        revoker = revokeCapabilities
        supportsPauseResume = false
        plans = []
        planIndex = 0
        receivedBytes = 0
        expectedBytes = nil
        transition(.resolving(item: request.itemTitle, destination: request.destinationLabel))
        let activeID = operationID
        resolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await resolvePlans()
                try Task.checkCancellation()
                guard self.operationID == activeID else { return }
                self.plans = resolved
                guard !resolved.isEmpty else {
                    await self.fail(.noDownloadSource, operationID: activeID)
                    return
                }
                self.beginCurrentPlan(operationID: activeID, resumeOffset: 0)
            } catch is CancellationError {
                guard self.operationID == activeID else { return }
                self.cancel()
            } catch {
                guard self.operationID == activeID else { return }
                await self.fail(.preparationFailed, operationID: activeID)
            }
        }
    }

    func start(
        request: Request,
        plans: [AppleOfflineDownloadPlan],
        revokeCapabilities: @escaping CapabilityRevoker = { _ in }
    ) {
        start(request: request, resolvePlans: { plans }, revokeCapabilities: revokeCapabilities)
    }

    func pause() {
        guard case .downloading = state, let driver else { return }
        driver.pause()
    }

    func resume() {
        guard case .paused = state, partialURL != nil else { return }
        let activeID = operationID
        transition(.resuming(
            item: request?.itemTitle ?? "Download",
            destination: request?.destinationLabel ?? "OpenStream Offline Storage",
            received: receivedBytes,
            expected: expectedBytes
        ))
        beginCurrentPlan(operationID: activeID, resumeOffset: receivedBytes)
    }

    func cancel() {
        let title = request?.itemTitle ?? "Download"
        operationID = UUID()
        abandonCurrentWork(removePartial: true)
        transition(.cancelled(item: title))
        Task { @MainActor [plans, revoker] in
            await Self.revoke(plans: plans, using: revoker)
        }
    }

    func retry() {
        guard let request, let resolver else { return }
        start(request: request, resolvePlans: resolver, revokeCapabilities: revoker ?? { _ in })
    }

    func loadExisting(mediaID: String, itemTitle: String) async {
        guard !state.ownsDownload else { return }
        let lookupID = UUID()
        operationID = lookupID
        transition(.idle)
        guard let record = await store.record(for: mediaID), !Task.isCancelled,
              operationID == lookupID, !state.ownsDownload else { return }
        let bytes = fileByteCount(at: record.localURL)
        transition(.completed(
            item: itemTitle,
            destination: record.localURL,
            bytes: bytes,
            container: record.container
        ))
    }

    func record(for mediaID: String) async -> AppleOfflineRecord? {
        await store.record(for: mediaID)
    }

    var partialFileURLForTesting: URL? { partialURL }

    private func beginCurrentPlan(operationID activeID: UUID, resumeOffset: Int64) {
        guard operationID == activeID, plans.indices.contains(planIndex), let request else { return }
        let plan = plans[planIndex]
        let scheme = plan.sourceURL.scheme?.lowercased()
        let usesProgressiveHTTP = (scheme == "http" || scheme == "https")
            && plan.requestHeaders.isEmpty
            && !["m3u", "m3u8"].contains(plan.sourceURL.pathExtension.lowercased())

        guard usesProgressiveHTTP else {
            supportsPauseResume = false
            transition(.downloading(
                item: request.itemTitle,
                destination: request.destinationLabel,
                received: 0,
                expected: nil
            ))
            resolutionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let record = try await self.store.makeAvailable(
                        mediaID: request.mediaID,
                        sourceURL: plan.sourceURL,
                        requestHeaders: plan.requestHeaders,
                        title: request.itemTitle,
                        subtitle: request.subtitle,
                        artworkURL: request.artworkURL
                    )
                    try Task.checkCancellation()
                    guard self.operationID == activeID else { return }
                    await self.complete(record, operationID: activeID)
                } catch is CancellationError {
                    guard self.operationID == activeID else { return }
                    self.cancel()
                } catch {
                    guard self.operationID == activeID else { return }
                    await self.advanceAfterFailure(.preparationFailed, operationID: activeID)
                }
            }
            return
        }

        supportsPauseResume = true

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            if resumeOffset == 0 || partialURL == nil {
                removePartialFile()
                let sourceExtension = plan.sourceURL.pathExtension.isEmpty ? "media" : plan.sourceURL.pathExtension.lowercased()
                let url = temporaryDirectory.appending(path: ".openstream-\(UUID().uuidString).\(sourceExtension)")
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    Task { await fail(.storageUnavailable, operationID: activeID) }
                    return
                }
                partialURL = url
                receivedBytes = 0
                expectedBytes = nil
            }
            guard let partialURL else { return }

            if resumeOffset == 0 {
                transition(.downloading(
                    item: request.itemTitle,
                    destination: request.destinationLabel,
                    received: 0,
                    expected: nil
                ))
            }
            let driver = AppleOfflineDataTaskDriver(
                configuration: sessionConfiguration,
                sourceURL: plan.sourceURL,
                partialURL: partialURL,
                resumeOffset: resumeOffset
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handle(event, operationID: activeID)
                }
            }
            self.driver = driver
            driver.start()
        } catch {
            Task { await advanceAfterFailure(.storageUnavailable, operationID: activeID) }
        }
    }

    private func handle(_ event: AppleOfflineDataTaskDriver.Event, operationID activeID: UUID) async {
        guard operationID == activeID, let request else { return }
        switch event {
        case .response(let received, let expected, let restarted):
            receivedBytes = received
            expectedBytes = expected
            if restarted {
                transition(.resuming(
                    item: request.itemTitle,
                    destination: request.destinationLabel,
                    received: 0,
                    expected: expected
                ))
            }
            transition(.downloading(
                item: request.itemTitle,
                destination: request.destinationLabel,
                received: received,
                expected: expected
            ))
        case .progress(let received, let expected):
            receivedBytes = max(receivedBytes, received)
            expectedBytes = expected ?? expectedBytes
            transition(.downloading(
                item: request.itemTitle,
                destination: request.destinationLabel,
                received: receivedBytes,
                expected: expectedBytes
            ))
        case .paused:
            driver = nil
            transition(.paused(
                item: request.itemTitle,
                destination: request.destinationLabel,
                received: receivedBytes,
                expected: expectedBytes
            ))
        case .cancelled:
            driver = nil
            removePartialFile()
            transition(.cancelled(item: request.itemTitle))
            await Self.revoke(plans: plans, using: revoker)
        case .finished:
            driver = nil
            guard let partialURL else {
                await advanceAfterFailure(.storageUnavailable, operationID: activeID)
                return
            }
            do {
                let record = try await store.makeAvailable(
                    mediaID: request.mediaID,
                    sourceURL: partialURL,
                    title: request.itemTitle,
                    subtitle: request.subtitle,
                    artworkURL: request.artworkURL
                )
                guard operationID == activeID else { return }
                removePartialFile()
                await complete(record, operationID: activeID)
            } catch {
                await advanceAfterFailure(.storageUnavailable, operationID: activeID)
            }
        case .failed(let failure):
            driver = nil
            if failure == .invalidResume, receivedBytes > 0 {
                removePartialFile()
                receivedBytes = 0
                expectedBytes = nil
                transition(.resuming(
                    item: request.itemTitle,
                    destination: request.destinationLabel,
                    received: 0,
                    expected: nil
                ))
                beginCurrentPlan(operationID: activeID, resumeOffset: 0)
            } else {
                await advanceAfterFailure(failure, operationID: activeID)
            }
        }
    }

    private func advanceAfterFailure(_ failure: AppleOfflineDownloadFailure, operationID activeID: UUID) async {
        guard operationID == activeID else { return }
        removePartialFile()
        if planIndex + 1 < plans.count {
            planIndex += 1
            receivedBytes = 0
            expectedBytes = nil
            beginCurrentPlan(operationID: activeID, resumeOffset: 0)
        } else {
            await fail(failure, operationID: activeID)
        }
    }

    private func complete(_ record: AppleOfflineRecord, operationID activeID: UUID) async {
        guard operationID == activeID, let request else { return }
        transition(.completed(
            item: request.itemTitle,
            destination: record.localURL,
            bytes: fileByteCount(at: record.localURL),
            container: record.container
        ))
        await Self.revoke(plans: plans, using: revoker)
    }

    private func fail(_ failure: AppleOfflineDownloadFailure, operationID activeID: UUID) async {
        guard operationID == activeID else { return }
        removePartialFile()
        transition(.failed(item: request?.itemTitle ?? "Download", message: failure.message))
        await Self.revoke(plans: plans, using: revoker)
    }

    private static func revoke(plans: [AppleOfflineDownloadPlan], using revoker: CapabilityRevoker?) async {
        let capabilities = Array(Set(plans.compactMap(\.protectedCapabilityToRevoke)))
        guard !capabilities.isEmpty else { return }
        await revoker?(capabilities)
    }

    private func abandonCurrentWork(removePartial: Bool) {
        resolutionTask?.cancel()
        resolutionTask = nil
        driver?.cancel()
        driver = nil
        if removePartial { removePartialFile() }
    }

    private func removePartialFile() {
        guard let partialURL else { return }
        if fileManager.fileExists(atPath: partialURL.path) {
            try? fileManager.removeItem(at: partialURL)
        }
        self.partialURL = nil
    }

    private func transition(_ next: State) {
        let previous = state
        state = next
        // Trace phase changes only; progress ticks arrive many times a second.
        if previous.phaseName != next.phaseName {
            if case .failed = next {
                AppleInteractionTrace.record(.failure, "download \(String(describing: next).prefix(160))")
            } else {
                AppleInteractionTrace.record(.network, "download \(String(describing: next).prefix(160))")
            }
        }
        publishLiveActivity(next)
        // `stateDidChange` belongs to whoever is driving a batch — the season
        // queue claims and releases it — so the Live Activity is driven from
        // here instead of competing for that one slot.
        stateDidChange?(next)
    }

    /// Mirrors the state onto the download Live Activity. A no-op off iOS and
    /// when the viewer has Live Activities turned off for the app.
    private func publishLiveActivity(_ next: State) {
        guard let request else { return }
        let controller = AppleDownloadLiveActivityController.shared
        let status: AppleDownloadActivityPresentation.Status
        var received: Int64 = 0
        var expected: Int64?
        switch next {
        case .idle:
            controller.end()
            return
        case .resolving:
            status = .resolving
        case .downloading(_, _, let got, let total):
            status = .downloading
            received = got
            expected = total
        case .paused(_, _, let got, let total):
            status = .paused
            received = got
            expected = total
        case .resuming(_, _, let got, let total):
            status = .resuming
            received = got
            expected = total
        case .completed(_, _, let bytes, _):
            status = .completed
            received = bytes
            expected = bytes
        case .failed(_, let message):
            status = .failed(message)
        case .cancelled:
            status = .cancelled
        }
        controller.apply(
            title: request.itemTitle,
            subtitle: request.subtitle,
            destination: request.destinationLabel,
            state: AppleDownloadActivityPresentation.state(
                received: received, expected: expected, status: status
            )
        )
    }

    private func fileByteCount(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private final class AppleOfflineDataTaskDriver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(received: Int64, expected: Int64?, restarted: Bool)
        case progress(received: Int64, expected: Int64?)
        case paused
        case cancelled
        case finished
        case failed(AppleOfflineDownloadFailure)
    }

    private enum StopReason { case pause, cancel }

    private let configuration: URLSessionConfiguration
    private let sourceURL: URL
    private let partialURL: URL
    private let resumeOffset: Int64
    private let event: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var stopReason: StopReason?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var received: Int64
    private var expected: Int64?
    private var failure: AppleOfflineDownloadFailure?

    init(
        configuration: URLSessionConfiguration,
        sourceURL: URL,
        partialURL: URL,
        resumeOffset: Int64,
        event: @escaping @Sendable (Event) -> Void
    ) {
        self.configuration = configuration
        self.sourceURL = sourceURL
        self.partialURL = partialURL
        self.resumeOffset = resumeOffset
        self.received = resumeOffset
        self.event = event
    }

    func start() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 60
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func pause() {
        setStopReason(.pause)
        task?.cancel()
    }

    func cancel() {
        setStopReason(.cancel)
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = .invalidResponse
            completionHandler(.cancel)
            return
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            failure = resumeOffset > 0 && http.statusCode == 416 ? .invalidResume : .httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }

        let restarted = resumeOffset > 0 && http.statusCode != 206
        do {
            let handle = try FileHandle(forWritingTo: partialURL)
            if restarted || resumeOffset == 0 {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                received = 0
            } else {
                try handle.seekToEnd()
                received = resumeOffset
            }
            fileHandle = handle
        } catch {
            failure = .storageUnavailable
            completionHandler(.cancel)
            return
        }

        let responseLength = response.expectedContentLength
        expected = responseLength >= 0
            ? (http.statusCode == 206 ? received + responseLength : responseLength)
            : nil
        event(.response(received: received, expected: expected, restarted: restarted))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            received += Int64(data.count)
            event(.progress(received: received, expected: expected))
        } catch {
            failure = .storageUnavailable
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? fileHandle?.close()
        fileHandle = nil
        self.task = nil
        session.finishTasksAndInvalidate()
        self.session = nil

        if let reason = takeStopReason() {
            event(reason == .pause ? .paused : .cancelled)
            return
        }
        if let failure {
            event(.failed(failure))
            return
        }
        if let error {
            let code = (error as? URLError)?.code
            switch code {
            case .timedOut:
                event(.failed(.timedOut))
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                event(.failed(.networkUnavailable))
            case .cancelled where resumeOffset > 0:
                event(.failed(.invalidResume))
            default:
                event(.failed(.invalidResponse))
            }
            return
        }
        event(.finished)
    }

    private func setStopReason(_ value: StopReason) {
        lock.lock()
        stopReason = value
        lock.unlock()
    }

    private func takeStopReason() -> StopReason? {
        lock.lock()
        let value = stopReason
        stopReason = nil
        lock.unlock()
        return value
    }
}
