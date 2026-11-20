import Foundation
import Testing
@testable import OpenStreamApple

struct AppleImportProgressTests {
    @Test(arguments: [false, true])
    func validationAnnouncesOnlyAnExplicitFirstImport(announcesImport: Bool) async throws {
        let name = UUID().uuidString
        let url = try #require(URL(string: "https://fixture.example/list.m3u"))
        let source = AppleSource(kind: .liveTV, name: name, url: url, iptvType: .m3u)
        let client = AppleIPTVClient(loader: { request in
            let announced = await MainActor.run {
                AppleImportStore.shared.operations.contains { $0.title == name }
            }
            #expect(announced == announcesImport)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("#EXTM3U\n#EXTINF:-1,Fixture\nhttps://fixture.example/live.m3u8\n".utf8), response)
        })
        let channels = try await client.validate(source: source, announcesImport: announcesImport)
        #expect(channels.count == 1)
    }

    @Test(arguments: [false, true])
    func validationAndRefreshAreQuietByDefault(refresh: Bool) async throws {
        let name = UUID().uuidString
        let url = try #require(URL(string: "https://fixture.example/list.m3u"))
        let source = AppleSource(kind: .liveTV, name: name, url: url, iptvType: .m3u)
        let client = AppleIPTVClient(loader: { _ in
            let announced = await MainActor.run {
                AppleImportStore.shared.operations.contains { $0.title == name }
            }
            #expect(!announced)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("#EXTM3U\n#EXTINF:-1,Fixture\nhttps://fixture.example/live.m3u8\n".utf8), response)
        })
        let channels = try await (refresh ? client.channels(source: source) : client.validate(source: source))
        #expect(channels.count == 1)
    }

    @Test func progressHandlesUnknownLengthAndClampsKnownLength() {
        #expect(AppleImportProgress(items: 0, bytes: 42, totalBytes: 0).bytes == 42)
        #expect(AppleImportProgress(items: 0, bytes: 200, totalBytes: 100).bytes == 100)
        #expect(AppleImportProgress(items: 0, bytes: -1, totalBytes: 100).bytes == 0)
    }
    @Test func detailLeavesOutZeroCounts() {
        #expect(AppleImportProgress(items: 0, bytes: 0, totalBytes: 0).detail(unit: "channels") == nil)
        #expect(AppleImportProgress(items: 0, bytes: 2048, totalBytes: 0).detail(unit: "channels") == "2 KB")
        #expect(AppleImportProgress(items: 12, bytes: 0, totalBytes: 0).detail(unit: "channels") == "12 channels")
    }
    @Test func downloadReportsReceivedByteCount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportProgressURLProtocol.self]
        let client = AppleBoundedHTTPClient(configuration: configuration)
        let recorder = ProgressRecorder()
        let (data, _) = try await client.load(URLRequest(url: URL(string: "https://fixture.example/progress")!),
            maximumBytes: 100, redirectPolicy: .reject, behavior: .rejectOverflow) { bytes, total in
                recorder.record(.init(items: 0, bytes: bytes, totalBytes: Int(total), phase: .downloading))
            }
        #expect(data.count == 12)
        #expect(recorder.values.last?.bytes == 12)
        #expect(recorder.values.isEmpty == false)
        #expect(recorder.values.allSatisfy { $0.bytes > 0 && $0.bytes <= 12 })
        #expect(recorder.values.last?.totalBytes == 12)
        #expect(recorder.values.last?.phase == .downloading)
    }

    @Test func playlistReportsCountsAndBytes() throws {
        let data = Data(("#EXTM3U\n" + (0..<300).map { "#EXTINF:-1 tvg-id=\"\($0)\",Channel \($0)\nhttps://fixture.example/\($0).m3u8\n" }.joined()).utf8)
        let recorder = ProgressRecorder()
        let channels = try AppleIPTVClient.parseM3U(data, sourceID: UUID(), baseURL: URL(string: "https://fixture.example/list.m3u")!, progress: recorder.record)
        #expect(channels.count == 300)
        #expect(recorder.values.last?.items == 300)
        #expect(recorder.values.last?.bytes == data.count)
        #expect(recorder.values.count > 1)
    }

    @Test func playlistCancellationDuringParsingRejectsPartialResults() async {
        let task = Task {
            let data = Data(("#EXTM3U\n" + (0..<1000).map { "#EXTINF:-1,Channel \($0)\nhttps://fixture.example/\($0).m3u8\n" }.joined()).utf8)
            return try AppleIPTVClient.parseM3U(data, sourceID: UUID(), baseURL: URL(string: "https://fixture.example")!) { progress in
                if progress.items >= 100 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor @Test func cancelControlCancelsWorkerAndRemovesProgress() async {
        let store = AppleImportStore()
        let task = Task {
            try await store.run(title: "Fixture", unit: "channels") { report in
                report(.init(items: 1, bytes: 1, totalBytes: 100))
                while true { try Task.checkCancellation(); await Task.yield() }
                return 1
            }
        }
        while store.operations.first?.progress.items != 1 { await Task.yield() }
        store.operations.first?.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.operations.isEmpty)
    }

    @Test func cancelledPlaylistDoesNotReturnPartialResults() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AppleIPTVClient.parseM3U(Data("#EXTM3U\n".utf8), sourceID: UUID(), baseURL: URL(string: "https://fixture.example")!)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func xmlFailureRejectsPartialGuide() throws {
        #expect(throws: (any Error).self) {
            try AppleIPTVGuideXMLTVParser().validatedGuide(data: Data("<tv><programme".utf8))
        }
    }

    @Test func cancelledXMLDoesNotReturnPartialGuide() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AppleIPTVGuideXMLTVParser().validatedGuide(data: Data("<tv/>".utf8))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppleImportProgress] = []
    var values: [AppleImportProgress] { lock.withLock { stored } }
    func record(_ value: AppleImportProgress) { lock.withLock { stored.append(value) } }
}

private final class ImportProgressURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "12"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0..<3 { client?.urlProtocol(self, didLoad: Data("1234".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
