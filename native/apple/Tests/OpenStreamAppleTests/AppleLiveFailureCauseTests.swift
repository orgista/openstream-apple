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
        #expect(network == .channelServerUnreachable)
        #expect(network?.title == "Can’t reach this channel’s server")
        #expect(network?.action == .tryAgain)
        #expect(AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .cancelled, message: ""),
                                               channelName: "ESPN", sourceName: nil) == nil)
    }

    /// Measured 2026-11-07 on the owner's one-connection Xtream panel: "ABC
    /// SPARK" answers every viewer HTTP 403, text/html, empty body.
    @Test func aChannelRefusedForEveryoneIsThatChannelNotTheLoginOrALimit() async throws {
        let url = try #require(URL(string: "https://fixture.example/live/1.ts"))
        let probe = AppleIPTVStreamProbe { _ in
            (Data(), try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=UTF-8", "Server": "nginx"])))
        }
        let channel = AppleIPTVChannel(id: "spark", sourceID: UUID(), name: "ABC SPARK", streamURL: url)
        var thrown: (any Error)?
        do { _ = try await probe.validate(channel: channel) } catch { thrown = error }
        let error = try #require(thrown)
        #expect(error as? AppleIPTVError == .streamRequestFailed(403))
        #expect(AppleIPTVFailureCause.classify(error) != .streamLimit)
        let failure = ApplePlaybackFailure.classify(error)
        #expect(failure.isConnectionLimit == false)
        let cause = AppleLiveFailureCause.playback(failure, channelName: "ABC SPARK", sourceName: "Home IPTV")
        #expect(cause == .cannotPlay(channel: "ABC SPARK"))
        #expect(cause?.action == .nextChannel)
        #expect(AppleLiveFailureCause.playback(ApplePlaybackFailure(kind: .authentication, message: "x"),
                                               channelName: "ABC SPARK", sourceName: "Home IPTV")
                == .loginFailed(source: "Home IPTV"))
    }

    @Test func titlesStayShort() {
        let causes: [AppleLiveFailureCause] = [.unreachable(source: "Home"), .loginFailed(source: "Home"),
            .accountExpired(source: "Home"), .streamLimit(source: "Home"), .loadFailed(source: "Home"),
            .notBroadcasting(channel: "ESPN"), .cannotPlay(channel: "ESPN"), .channelServerUnreachable, .noSources]
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
                == ["All", "Favorites", "Pay-Per-View", "News"])
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

    /// The owner's provider: pay-per-view in an "EVENTS" group, most slots empty on a given day.
    @Test func anEventsGroupIsPayPerViewWithoutItsEmptySlots() {
        let source = UUID()
        let channels = ["EVENTS 01: 4pm UFC Fight Night", "EVENTS 24:", "EVENTS 02: 6pm WWE Money in the Bank"]
            .enumerated().map { index, name in
                AppleIPTVChannel(id: "\(index)", sourceID: source, name: name, group: "EVENTS",
                                 streamURL: URL(string: "https://fixture.example/\(index).ts")!)
            }
        #expect(channels.allSatisfy(AppleChannelVisibilityPolicy.isPayPerView))
        #expect(AppleLiveCategoryOrder.eventChannels(channels).map(\.id) == ["0", "2"])
    }

    @Test(arguments: [("EVENTS", true), ("Pay-Per-View", true), ("|PPV|", true), ("Live_Event", false),
                      ("US | SPORTS EVENTS", false), ("Special Events Channel", false)])
    func onlyAnEventsGroupByItselfIsPayPerView(group: String, expected: Bool) {
        let channel = AppleIPTVChannel(id: "1", sourceID: UUID(), name: "Feed 1", group: group,
                                       streamURL: URL(string: "https://fixture.example/1.ts")!)
        #expect(AppleChannelVisibilityPolicy.isPayPerView(channel) == expected)
    }
}
