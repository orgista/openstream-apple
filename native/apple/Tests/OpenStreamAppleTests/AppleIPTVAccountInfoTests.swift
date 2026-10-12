import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Provider account info")
struct AppleIPTVAccountInfoTests {
    @Test func expiryAndConnectionLimitsAreDistinct() {
        let now = Date(timeIntervalSince1970: 1000)
        let expired = AppleIPTVAccountInfo(expiration: "999", maxConnections: "2", activeConnections: "2", status: "Active")
        #expect(expired.rejection(now: now) == "Expired")
        let full = AppleIPTVAccountInfo(expiration: "2000", maxConnections: "2", activeConnections: "2", status: "Active")
        #expect(full.rejection(now: now) == "MaxConnections")
        #expect(full.streamsInUse == "2 of 2 streams in use")
        #expect(AppleIPTVAccountInfo(expiration: nil, maxConnections: "0", activeConnections: "3", status: "Active").rejection(now: now) == nil)
        #expect(AppleIPTVAccountInfo(expiration: "invalid", maxConnections: "bad", activeConnections: "-1", status: "Disabled").rejection(now: now) == "Disabled")
        #expect(AppleIPTVError.authenticationFailed(status: "Expired").localizedDescription != AppleIPTVError.authenticationFailed(status: nil).localizedDescription)
        #expect(AppleIPTVError.authenticationFailed(status: "MaxConnections").localizedDescription != AppleIPTVError.authenticationFailed(status: "Expired").localizedDescription)
    }

    @Test func mixedIntegerAndStringAccountFieldsDecode() async throws {
        let client = AppleIPTVClient { request in
            (Data(#"{"user_info":{"auth":1,"status":"Active","exp_date":"2000000000","max_connections":4,"active_cons":"2"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: URL(string: "https://fixture.example")!, iptvType: .xtream)
        let info = try await client.accountInfo(source: source, credentials: .init(username: "fixture", password: "fixture"))
        #expect(info.maxConnections == 4)
        #expect(info.activeConnections == 2)
        #expect(info.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    }
}
