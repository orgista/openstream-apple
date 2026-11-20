import Foundation
import Testing
@testable import OpenStreamApple

struct AppleQuickConnectPollingTests {
    private let baseURL = URL(string: "https://fixture.example/jellyfin")!
    private let ticket = AppleQuickConnectTicket(secret: "fixture-secret", code: "123456")

    @Test func approvalAuthenticatesAndReturnsLibrarySession() async throws {
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let json = url.path.hasSuffix("/QuickConnect/Connect")
                ? #"{"Authenticated":true}"#
                : #"{"AccessToken":"fixture-token","User":{"Id":"fixture-user"},"ServerId":"fixture-server"}"#
            return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let session = try await client.waitForQuickConnect(baseURL: baseURL, ticket: ticket, pollInterval: .zero)
        #expect(session.userID == "fixture-user")
        #expect(session.kind == .jellyfin)
    }

    @Test func unapprovedCodeStopsAtPollingLimit() async throws {
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            return (Data(#"{"Authenticated":false}"#.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        await #expect(throws: AppleMediaServerError.unsupported) {
            try await client.waitForQuickConnect(baseURL: baseURL, ticket: ticket, pollInterval: .zero, maximumPolls: 2)
        }
    }

    @Test func cancellationCannotAuthenticate() async {
        let client = AppleMediaServerClient(loader: { _ in
            Issue.record("A cancelled poll must not send a request")
            throw AppleMediaServerError.unreachable
        })
        let task = Task {
            try await client.waitForQuickConnect(baseURL: baseURL, ticket: ticket, pollInterval: .seconds(60))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
