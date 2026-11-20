import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

struct AppleSphericalByteSourceTests {
    private func source(_ path: String, protocolClass: URLProtocol.Type = SphericalRangeProtocol.self) throws -> AppleSphericalByteSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return AppleSphericalByteSource(url: try #require(URL(string: "https://fixture.example/" + path)), configuration: configuration)
    }

    @Test func acceptsAWholeFile200Response() async throws {
        let source = try source("whole")
        defer { source.cancel() }
        #expect(try await source.read(0..<8) == Data(0..<8))
    }

    @Test func acceptsShort206AndRejectsTheWrongOffset() async throws {
        let short = try source("short")
        let wrong = try source("wrong")
        defer { short.cancel(); wrong.cancel() }
        #expect(try await short.read(2..<7) == Data([2, 3]))
        await #expect(throws: URLError.self) { _ = try await wrong.read(2..<7) }
    }

    @Test func ignoresNeitherOversizedBodiesNorIgnoredRangeOffsets() async throws {
        let source = try source("whole")
        defer { source.cancel() }
        await #expect(throws: AppleBoundedHTTPError.responseTooLarge) { _ = try await source.read(2..<7) }
    }

    @Test func headAndRangeFallbackFindTheSameLength() async throws {
        let head = try source("whole")
        let fallback = try source("head-unsupported")
        defer { head.cancel(); fallback.cancel() }
        #expect(try await head.size() == 8)
        #expect(try await fallback.size() == 8)
    }

    @Test func teardownRejectsSubsequentReads() async throws {
        let source = try source("whole")
        source.cancel()
        source.cancel()
        await #expect(throws: CancellationError.self) { _ = try await source.read(0..<8) }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func stalledReadsAreCancelledAtTheTransport(cancelSession: Bool) async throws {
        let source = try source("stall", protocolClass: SphericalStallProtocol.self)
        defer { source.cancel() }
        let work = Task { try await source.read(0..<8) }
        var started = SphericalStallProtocol.started.stream.makeAsyncIterator()
        _ = await started.next()
        if cancelSession { source.cancel() } else { work.cancel() }
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        var stopped = SphericalStallProtocol.stopped.stream.makeAsyncIterator()
        #expect(await stopped.next() != nil)
    }
}

private final class SphericalRangeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let isHead = request.httpMethod == "HEAD"
        let headUnsupported = url.lastPathComponent == "head-unsupported" && isHead
        let partial = ["short", "wrong"].contains(url.lastPathComponent)
        var headers = ["Content-Length": partial ? "2" : "8"]
        if partial { headers["Content-Range"] = url.lastPathComponent == "wrong" ? "bytes 0-1/8" : "bytes 2-3/8" }
        guard let response = HTTPURLResponse(url: url, statusCode: headUnsupported ? 405 : (partial ? 206 : 200),
                                             httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !isHead { client?.urlProtocol(self, didLoad: partial ? Data([2, 3]) : Data(0..<8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SphericalStallProtocol: URLProtocol {
    static let started = AsyncStream<Void>.makeStream()
    static let stopped = AsyncStream<Void>.makeStream()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.continuation.yield(()) }
    override func stopLoading() { Self.stopped.continuation.yield(()) }
}

struct AppleImmersiveProbeDeadlineTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aNonCooperativeProbeCannotHoldTheCaller(cancelCaller: Bool) async {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let cancelled = Mutex(false)
        let started = AsyncStream<Void>.makeStream()
        let work = Task {
            await AppleImmersiveProbeDeadline.run(timeout: cancelCaller ? .seconds(60) : .milliseconds(100), cancel: {
                cancelled.withLock { $0 = true }
            }) {
                await withCheckedContinuation { continuation in
                    gate.withLock { $0 = continuation }
                    started.continuation.yield(())
                }
                return 7
            }
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        if cancelCaller { work.cancel() }
        #expect(await work.value == nil)
        #expect(cancelled.withLock { $0 })
        gate.withLock { $0?.resume(); $0 = nil }
    }

    @Test func successfulProbeReturnsItsValueWithoutCancellingTheSource() async {
        let cancelled = Mutex(false)
        let result = await AppleImmersiveProbeDeadline.run(cancel: { cancelled.withLock { $0 = true } }) { 9 }
        #expect(result == 9)
        #expect(cancelled.withLock { $0 } == false)
    }
}

@MainActor
struct AppleSphericalLoadQueueTests {
    @Test(.timeLimit(.minutes(1)))
    func limitsConcurrencyCancelsQueuedWorkAndCancelsActiveWork() async {
        let queue = AppleSphericalLoadQueue()
        let requests = (0..<4).map { _ in NSObject() }
        let started = AsyncStream<Int>.makeStream()
        let stopped = AsyncStream<Int>.makeStream()
        for (index, request) in requests.enumerated() {
            #expect(queue.submit(id: ObjectIdentifier(request)) {
                started.continuation.yield(index)
                let gate = AsyncStream<Void>.makeStream()
                for await _ in gate.stream {}
                stopped.continuation.yield(index)
            })
        }
        var events = started.stream.makeAsyncIterator()
        #expect(await events.next() == 0)
        #expect(await events.next() == 1)
        #expect(queue.activeCount == 2)
        #expect(queue.pendingCount == 2)
        queue.cancel(id: ObjectIdentifier(requests[2]))
        #expect(queue.pendingCount == 1)
        queue.cancel(id: ObjectIdentifier(requests[0]))
        #expect(await events.next() == 3)
        queue.cancelAll()
        var completions = stopped.stream.makeAsyncIterator()
        var ended: Set<Int> = []
        for _ in 0..<3 { if let index = await completions.next() { ended.insert(index) } }
        #expect(ended == [0, 1, 3])
        #expect(queue.submit(id: ObjectIdentifier(NSObject())) {} == false)
    }

    @Test func capsPendingRequests() {
        let queue = AppleSphericalLoadQueue()
        let requests = (0..<19).map { _ in NSObject() }
        for request in requests.prefix(18) { #expect(queue.submit(id: ObjectIdentifier(request)) {}) }
        #expect(queue.submit(id: ObjectIdentifier(requests[18])) {} == false)
        queue.cancelAll()
    }
}
