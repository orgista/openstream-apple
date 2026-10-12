import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Live failure causes")
struct AppleLiveFailureCauseTests {
    @Test func aBlockedPanelIsUnreachableNeverAStreamLimit() {
        for error: any Error in [AppleIPTVError.httpStatus(403), AppleIPTVError.httpStatus(429),
                                 AppleIPTVError.unexpectedResponse(contentType: "text/html"),
                                 URLError(.timedOut), URLError(.cannotConnectToHost)] {
            let cause = AppleLiveFailureCause.source(error, sourceName: "Home IPTV")
            #expect(cause == .unreachable(source: "Home IPTV"))
            #expect(!cause.title.contains("stream limit"))
            #expect(cause.action == .tryAgain)
            #expect(cause.systemImage == "wifi.exclamationmark")
        }
    }

    @Test func onlyThePanelsOwnStatusIsAStreamLimit() {
        let cause = AppleLiveFailureCause.source(AppleIPTVError.authenticationFailed(status: "MaxConnections"),
                                                 sourceName: "Home IPTV")
        #expect(cause == .streamLimit(source: "Home IPTV"))
        #expect(cause.title == "Home IPTV stream limit")
        #expect(cause.systemImage == "person.2.slash")
    }

    @Test func loginProblemsOpenSettings() {
        #expect(AppleLiveFailureCause.source(AppleIPTVError.authenticationFailed(status: "Expired"),
                                             sourceName: "Home IPTV") == .accountExpired(source: "Home IPTV"))
        let failed = AppleLiveFailureCause.source(AppleIPTVError.authenticationFailed(status: nil), sourceName: "Home IPTV")
        #expect(failed == .loginFailed(source: "Home IPTV"))
        #expect(failed.action == .openSettings)
    }

    @Test func channelFailuresNameTheChannel() {
        let dead = AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .sourceEnded, message: "eof"),
                                                  channelName: "ESPN", sourceName: "Home IPTV")
        #expect(dead?.title == "ESPN isn’t broadcasting")
        #expect(dead?.action == .nextChannel)
        let unsupported = AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .unsupportedMedia, message: "x"),
                                                         channelName: "ESPN", sourceName: nil)
        #expect(unsupported?.title == "ESPN can’t play here")
        let network = AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .network, message: "x"),
                                                     channelName: "ESPN", sourceName: "Home IPTV")
        #expect(network == .unreachable(source: "Home IPTV"))
        #expect(AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .cancelled, message: ""),
                                               channelName: "ESPN", sourceName: nil) == nil)
    }

    @Test func titlesStayShort() {
        let causes: [AppleLiveFailureCause] = [.unreachable(source: "Home"), .loginFailed(source: "Home"),
            .accountExpired(source: "Home"), .streamLimit(source: "Home"), .loadFailed(source: "Home"),
            .notBroadcasting(channel: "ESPN"), .cannotPlay(channel: "ESPN"), .noSources]
        for cause in causes {
            #expect(cause.title.split(separator: " ").count <= 5)
        }
        #expect(AppleLiveFailureCause.noSources.action == .addSource)
    }

    @Test func blankNamesFallBack() {
        #expect(AppleLiveFailureCause.source(URLError(.timedOut), sourceName: "  ") == .unreachable(source: "Live TV"))
    }
}

@Suite("Live category row")
struct AppleLiveCategoryOrderTests {
    @Test func favoritesAndEventsOnlyWhenThereAreAny() {
        #expect(AppleLiveCategoryOrder.tabs(groups: ["News", "Sports"], hasFavorites: false, eventCount: 0)
                == ["All", "News", "Sports"])
        #expect(AppleLiveCategoryOrder.tabs(groups: ["All", "Favorites", "News"], hasFavorites: true, eventCount: 3)
                == ["All", "Favorites", "Events", "News"])
    }

    @Test func aVanishedTabFallsBackToAll() {
        #expect(AppleLiveCategoryOrder.resolved("Favorites", in: ["All", "News"]) == "All")
        #expect(AppleLiveCategoryOrder.resolved("News", in: ["All", "News"]) == "News")
    }

    @Test func eventsArePayPerViewChannelsByName() {
        let source = UUID()
        let channels = [
            AppleIPTVChannel(id: "1", sourceID: source, name: "UFC 300 PPV", group: "Events",
                             streamURL: URL(string: "https://fixture.example/1.ts")!),
            AppleIPTVChannel(id: "2", sourceID: source, name: "ESPN", group: "Sports",
                             streamURL: URL(string: "https://fixture.example/2.ts")!),
            AppleIPTVChannel(id: "3", sourceID: source, name: "Boxing", group: "Pay-Per-View",
                             streamURL: URL(string: "https://fixture.example/3.ts")!),
        ]
        #expect(AppleLiveCategoryOrder.eventChannels(channels).map(\.id) == ["3", "1"])
    }
}
