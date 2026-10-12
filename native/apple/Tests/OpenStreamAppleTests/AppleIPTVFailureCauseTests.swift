import Foundation
import Testing
@testable import OpenStreamApple

/// Owner item 20 (2026-10-09): the stream-limit message only when the panel
/// says so; a panel that does not answer is "Can’t reach <provider>".
@Suite struct AppleIPTVFailureCauseTests {
    @Test func thePanelsOwnMaxConnectionsIsAStreamLimit() {
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.authenticationFailed(status: "MaxConnections")) == .streamLimit)
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.authenticationFailed(status: " maxconnections ")) == .streamLimit)
    }

    @Test func activeConnectionsAtTheMaximumBecomeAStreamLimit() throws {
        let full = AppleIPTVAccountInfo(expiration: nil, maxConnections: "1", activeConnections: "1", status: "Active")
        let status = try #require(full.rejection(now: .now))
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.authenticationFailed(status: status)) == .streamLimit)
        let free = AppleIPTVAccountInfo(expiration: nil, maxConnections: "2", activeConnections: "1", status: "Active")
        #expect(free.rejection(now: .now) == nil)
    }

    @Test func otherRejectionsAreNotAStreamLimit() {
        for status in [nil, "Expired", "Banned", "Disabled", "Active"] {
            #expect(AppleIPTVFailureCause.classify(AppleIPTVError.authenticationFailed(status: status)) == .other)
        }
    }

    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                      .notConnectedToInternet, .secureConnectionFailed])
    func aPanelThatDoesNotAnswerIsUnreachable(code: URLError.Code) {
        #expect(AppleIPTVFailureCause.classify(URLError(code)) == .unreachable)
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.unreachable(URLError(code).localizedDescription)) == .unreachable)
    }

    @Test func blockPagesAndServerErrorsAreUnreachable() {
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.httpStatus(403)) == .unreachable)
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.unexpectedResponse(contentType: "text/html")) == .unreachable)
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.requestFailed(503)) == .unreachable)
        #expect(AppleIPTVFailureCause.classify(AppleIPTVError.requestFailed(404)) == .other)
        #expect(AppleIPTVFailureCause.classify(URLError(.cancelled)) == .other)
    }

    @Test func messagesNameTheProvider() {
        let timedOut = AppleIPTVFailureCause.message(for: URLError(.timedOut), providerName: "Home IPTV")
        #expect(timedOut == "Can’t reach Home IPTV.")
        #expect(!timedOut.contains("stream limit"))
        let limit = AppleIPTVFailureCause.message(for: AppleIPTVError.authenticationFailed(status: "MaxConnections"),
                                                  providerName: "Home IPTV")
        #expect(limit.hasPrefix("Home IPTV: "))
        #expect(limit.contains("stream limit"))
        #expect(AppleIPTVFailureCause.message(for: URLError(.timedOut), providerName: " ") == "Can’t reach your Live TV provider.")
    }

    @Test func aFailureThatNamesItsProviderIsNotPrefixedTwice() {
        let source = AppleSource(kind: .liveTV, name: "Home IPTV", url: URL(string: "https://fixture.example")!, iptvType: .xtream)
        var load = AppleLiveSourceLoad(sources: [source])
        load.failed(source.id, message: AppleIPTVFailureCause.message(for: URLError(.timedOut), providerName: "Home IPTV"))
        #expect(load.failures.map(\.text) == ["Can’t reach Home IPTV."])
    }

    /// Owner item 18: the Library says which provider's library is down.
    @Test func theLibraryNamesTheProvider() {
        #expect(AppleXtreamLibraryError.unavailableMessage(providerName: "Home IPTV") == "Home IPTV’s movies and series are unavailable.")
        #expect(AppleXtreamLibraryError.unavailableMessage(providerName: "Strong Hits") == "Strong Hits’ movies and series are unavailable.")
        #expect(AppleXtreamLibraryError.unavailableMessage(providerName: "  ") == AppleXtreamLibraryError.unavailable.localizedDescription)
    }
}
