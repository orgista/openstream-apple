import Foundation
import Testing
@testable import OpenStreamApple

private final class OfflineDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture {
        var data = Data()
        var chunkSize = 16_384
        var chunkDelay: TimeInterval = 0.005
        var ignoreRange = false
        var failOnce: URLError.Code?
        var requests: [URLRequest] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture()
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(
        data: Data,
        chunkSize: Int = 16_384,
        chunkDelay: TimeInterval = 0.005,
        ignoreRange: Bool = false,
        failOnce: URLError.Code? = nil
    ) {
        lock.lock()
        fixture = Fixture(
            data: data,
            chunkSize: chunkSize,
            chunkDelay: chunkDelay,
            ignoreRange: ignoreRange,
            failOnce: failOnce,
            requests: []
        )
        lock.unlock()
    }

    static func setIgnoreRange(_ value: Bool) {
        lock.lock()
        fixture.ignoreRange = value
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        let value = fixture.requests
        lock.unlock()
        return value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "offline.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.fixture.requests.append(request)
        let data = Self.fixture.data
        let chunkSize = Self.fixture.chunkSize
        let delay = Self.fixture.chunkDelay
        let ignoreRange = Self.fixture.ignoreRange
        let failure = Self.fixture.failOnce
        Self.fixture.failOnce = nil
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }

        let requestedOffset = request.value(forHTTPHeaderField: "Range")
            .flatMap { value -> Int? in
                guard value.hasPrefix("bytes="), let first = value.dropFirst(6).split(separator: "-").first else { return nil }
                return Int(first)
            } ?? 0
        let offset = ignoreRange ? 0 : min(requestedOffset, data.count)
        let body = data.dropFirst(offset)
        let status = requestedOffset > 0 && !ignoreRange ? 206 : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(body.count),
                "Accept-Ranges": "bytes",
                "Content-Type": "video/mp4",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        var index = body.startIndex
        while index < body.endIndex {
            if isStopped { return }
            let end = body.index(index, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            client?.urlProtocol(self, didLoad: Data(body[index ..< end]))
            index = end
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        if !isStopped { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock()
        let value = stopped
        stateLock.unlock()
        return value
    }
}

@MainActor
private func waitForDownloadState(
    timeout: Duration = .seconds(4),
    _ predicate: @escaping (AppleOfflineDownloadCoordinator.State) -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate(DownloadTestContext.coordinator.state) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for download state: \(DownloadTestContext.coordinator.state)")
}

@MainActor
private enum DownloadTestContext {
    static var coordinator = AppleOfflineDownloadCoordinator()
}

@Suite(.serialized)
@MainActor
struct AppleOfflineDownloadCoordinatorTests {
    private func makeContext(data: Data) throws -> (AppleOfflineDownloadCoordinator, AppleOfflineMediaStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-download-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppleOfflineMediaStore(
            rootDirectory: root.appending(path: "library", directoryHint: .isDirectory),
            allowedDirectories: [root]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineDownloadURLProtocol.self]
        let coordinator = AppleOfflineDownloadCoordinator(
            store: store,
            sessionConfiguration: configuration,
            temporaryDirectory: root.appending(path: "partials", directoryHint: .isDirectory)
        )
        DownloadTestContext.coordinator = coordinator
        OfflineDownloadURLProtocol.configure(data: data)
        return (coordinator, store, root)
    }

    private func request() -> AppleOfflineDownloadCoordinator.Request {
        .init(
            mediaID: "movie:fixture",
            itemTitle: "Sample Movie",
            subtitle: nil,
            artworkURL: nil,
            destinationLabel: "OpenStream Offline Storage"
        )
    }

    private func plan() -> AppleOfflineDownloadPlan {
        .init(
            sourceURL: URL(string: "https://offline.test/video.mp4")!,
            requestHeaders: [:],
            protectedCapabilityToRevoke: nil
        )
    }

    @Test func selectingMissingEpisodeClearsPreviousCompletedState() async throws {
        let (coordinator, _, root) = try makeContext(data: Data(repeating: 0x41, count: 1024))
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.start(request: request(), plans: [plan()])
        try await waitForDownloadState { $0.isCompleted }
        await coordinator.loadExisting(mediaID: "different:episode", itemTitle: "Second")
        #expect(coordinator.state == .idle)
    }

    @Test func seasonBridgeCancellationTerminatesTheTransfer() async throws {
        let (coordinator, store, root) = try makeContext(data: Data(repeating: 0x41, count: 2 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Task { @MainActor in
            try await coordinator.downloadAndWait(request: request(), resolvePlans: { [plan()] }, revokeCapabilities: { _ in })
        }
        try await waitForDownloadState { state in
            if case .downloading(_, _, let received, _) = state { return received > 0 }
            return false
        }
        work.cancel()
        do { try await work.value; Issue.record("Cancelled season transfer succeeded") }
        catch is CancellationError { }
        #expect(await store.record(for: request().mediaID) == nil)
        #expect(coordinator.partialFileURLForTesting == nil)
    }

    @Test func seasonBridgeWaitsForActualCompletionAndSkipsExistingFiles() async throws {
        let bytes = Data(repeating: 0x41, count: 1024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        var resolutions = 0
        for _ in 0..<2 {
            try await coordinator.downloadAndWait(request: request(), resolvePlans: {
                resolutions += 1
                return [plan()]
            }, revokeCapabilities: { _ in })
        }
        #expect(resolutions == 1)
        let record = try #require(await store.record(for: request().mediaID))
        #expect(try Data(contentsOf: record.localURL) == bytes)
    }

    @Test func progressIsMonotonicAndCompletionIsAtomic() async throws {
        let bytes = Data(repeating: 0x41, count: 512 * 1_024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        var progress: [Int64] = []
        coordinator.stateDidChange = { state in
            if case .downloading(_, _, let received, _) = state { progress.append(received) }
        }
        coordinator.start(request: request(), plans: [plan()])

        try await waitForDownloadState { $0.isCompleted }
        #expect(!progress.isEmpty)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
        let record = try #require(await store.record(for: "movie:fixture"))
        #expect(try Data(contentsOf: record.localURL) == bytes)
        #expect(coordinator.partialFileURLForTesting == nil)
    }

    @Test func pauseRetainsBytesAndResumeUsesHTTPRange() async throws {
        let bytes = Data(repeating: 0x42, count: 2 * 1_024 * 1_024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.start(request: request(), plans: [plan()])
        try await waitForDownloadState {
            if case .downloading(_, _, let received, _) = $0 { return received >= 65_536 }
            return false
        }
        coordinator.pause()
        try await waitForDownloadState { if case .paused = $0 { return true }; return false }
        let partial = try #require(coordinator.partialFileURLForTesting)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        coordinator.resume()
        try await waitForDownloadState { $0.isCompleted }

        let ranges = OfflineDownloadURLProtocol.recordedRequests().compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        #expect(ranges.contains { $0.hasPrefix("bytes=") && $0 != "bytes=0-" })
        let record = try #require(await store.record(for: "movie:fixture"))
        #expect(try Data(contentsOf: record.localURL) == bytes)
    }

    @Test func invalidResumeResponseSafelyRestartsFromZero() async throws {
        let bytes = Data(repeating: 0x43, count: 2 * 1_024 * 1_024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.start(request: request(), plans: [plan()])
        try await waitForDownloadState {
            if case .downloading(_, _, let received, _) = $0 { return received >= 65_536 }
            return false
        }
        coordinator.pause()
        try await waitForDownloadState { if case .paused = $0 { return true }; return false }
        OfflineDownloadURLProtocol.setIgnoreRange(true)
        coordinator.resume()
        try await waitForDownloadState { $0.isCompleted }

        let record = try #require(await store.record(for: "movie:fixture"))
        #expect(try Data(contentsOf: record.localURL) == bytes)
    }

    @Test func cancellationRemovesPartialAndNeverPublishesARecord() async throws {
        let bytes = Data(repeating: 0x44, count: 2 * 1_024 * 1_024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.start(request: request(), plans: [plan()])
        try await waitForDownloadState {
            if case .downloading(_, _, let received, _) = $0 { return received > 0 }
            return false
        }
        coordinator.cancel()
        #expect(coordinator.partialFileURLForTesting == nil)
        #expect(await store.record(for: "movie:fixture") == nil)
        if case .cancelled = coordinator.state {} else { Issue.record("Expected cancelled state") }
    }

    @Test func timeoutMapsToActionableFailureAndRetryCompletes() async throws {
        let bytes = Data(repeating: 0x45, count: 128 * 1_024)
        let (coordinator, store, root) = try makeContext(data: bytes)
        defer { try? FileManager.default.removeItem(at: root) }
        OfflineDownloadURLProtocol.configure(data: bytes, failOnce: .timedOut)
        coordinator.start(request: request(), plans: [plan()])
        try await waitForDownloadState { if case .failed = $0 { return true }; return false }
        if case .failed(_, let message) = coordinator.state {
            #expect(message.contains("timed out"))
        }
        coordinator.retry()
        try await waitForDownloadState { $0.isCompleted }
        #expect(await store.record(for: "movie:fixture") != nil)
    }

    @Test func localDownloadPlatformPolicyRejectsTVAndVision() {
        #expect(AppleLocalDownloadPlatformPolicy.isSupported(.iPhone))
        #expect(AppleLocalDownloadPlatformPolicy.isSupported(.iPad))
        #expect(AppleLocalDownloadPlatformPolicy.isSupported(.macOS))
        #expect(!AppleLocalDownloadPlatformPolicy.isSupported(.tvOS))
        #expect(!AppleLocalDownloadPlatformPolicy.isSupported(.visionOS))
    }
}
