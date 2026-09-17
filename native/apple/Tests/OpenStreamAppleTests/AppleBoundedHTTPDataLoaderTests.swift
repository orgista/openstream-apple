import Foundation
import Testing
@testable import OpenStreamApple

@Test func boundedHTTPClientRejectsChunkedOverflowBeforeAccumulatingIt() async {
    let client = AppleBoundedHTTPClient(configuration: boundedHTTPTestConfiguration(
        protocolClass: OverflowBoundedHTTPURLProtocol.self
    ))

    await #expect(throws: AppleBoundedHTTPError.responseTooLarge) {
        _ = try await client.load(
            URLRequest(url: URL(string: "https://overflow.example/test")!),
            maximumBytes: 8,
            redirectPolicy: .follow,
            behavior: .rejectOverflow
        )
    }
}

@Test func boundedHTTPClientReturnsOnlyTheRequestedMediaProbePrefix() async throws {
    let client = AppleBoundedHTTPClient(configuration: boundedHTTPTestConfiguration(
        protocolClass: PrefixBoundedHTTPURLProtocol.self
    ))

    let (data, response) = try await client.load(
        URLRequest(url: URL(string: "https://prefix.example/test")!),
        maximumBytes: 8,
        redirectPolicy: .follow,
        behavior: .returnPrefix
    )

    #expect(String(decoding: data, as: UTF8.self) == "abcdefgh")
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
}

private func boundedHTTPTestConfiguration(
    protocolClass: URLProtocol.Type
) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return configuration
}

private class BaseBoundedHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    class var statusCode: Int { 200 }
    class var chunks: [Data] { [] }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: Self.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OverflowBoundedHTTPURLProtocol: BaseBoundedHTTPURLProtocol, @unchecked Sendable {
    override class var chunks: [Data] {
        [Data("123456".utf8), Data("789012".utf8)]
    }
}

private final class PrefixBoundedHTTPURLProtocol: BaseBoundedHTTPURLProtocol, @unchecked Sendable {
    override class var statusCode: Int { 206 }
    override class var chunks: [Data] {
        [Data("abc".utf8), Data("defghijklmnop".utf8)]
    }
}
