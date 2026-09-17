import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15: "a dead channel could it be replaced?"
///
/// The provider lists the same network many times over, so a dead feed almost
/// always has a living sibling. The coordinator has been able to fall back
/// across streams since the on-demand work; live simply never handed it any
/// candidates, so every live trace read `attempt 0/0`.
@Suite("Live channel alternates")
struct AppleLiveChannelAlternatesTests {
    private typealias A = AppleLiveChannelAlternates
    private let source = UUID()

    private func channel(_ id: String, _ name: String, url: String, group: String = "News") -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: source, name: name, group: group, streamURL: URL(string: url)!)
    }

    private func never(_ url: URL) -> Bool { false }

    @Test func anotherFeedOfTheSameNetworkReplacesADeadOne() {
        let dead = channel("1", "CBS (EAST)", url: "http://p/1")
        let lineup = [
            dead,
            channel("2", "US: CBS East HD", url: "http://p/2"),
            channel("3", "CBS FHD", url: "http://p/3"),
            channel("4", "NBC (EAST)", url: "http://p/4"),
        ]
        let alternates = A.alternates(for: dead, in: lineup, hasRecentlyFailed: never)
        #expect(alternates.map(\.id) == ["2", "3"])
    }

    @Test func aDifferentNetworkIsNeverOfferedAsAReplacement() {
        let dead = channel("1", "CBS (EAST)", url: "http://p/1")
        let lineup = [dead, channel("9", "CBS Sports Network", url: "http://p/9"), channel("4", "NBC", url: "http://p/4")]
        // "CBS Sports Network" is a different channel, not another CBS feed.
        #expect(A.alternates(for: dead, in: lineup, hasRecentlyFailed: never).isEmpty)
    }

    @Test func theSameURLIsTheSameFeedAndIsSkipped() {
        let dead = channel("1", "CBS", url: "http://p/same")
        let lineup = [dead, channel("2", "CBS HD", url: "http://p/same"), channel("3", "CBS", url: "http://p/other")]
        #expect(A.alternates(for: dead, in: lineup, hasRecentlyFailed: never).map(\.id) == ["3"])
    }

    @Test func aFeedThatJustFailedIsTriedLastRatherThanImmediatelyAgain() {
        let dead = channel("1", "CBS", url: "http://p/1")
        let recentlyFailed = channel("2", "CBS HD", url: "http://p/2")
        let untried = channel("3", "CBS FHD", url: "http://p/3")
        let alternates = A.alternates(
            for: dead,
            in: [dead, recentlyFailed, untried],
            hasRecentlyFailed: { $0 == recentlyFailed.streamURL }
        )
        #expect(alternates.map(\.id) == ["3", "2"])
    }

    @Test func payPerViewAndPlaceholdersAreNotReplacements() {
        let dead = channel("1", "CBS", url: "http://p/1")
        let lineup = [
            dead,
            channel("2", "CBS", url: "http://p/2", group: "PPV Events"),
            channel("3", "CBS", url: "http://p/3"),
        ]
        let alternates = A.alternates(for: dead, in: lineup, hasRecentlyFailed: never)
        #expect(alternates.map(\.id) == ["3"])
    }

    @Test func theListIsCappedBecauseEachFeedCostsAConnection() {
        let dead = channel("0", "CBS", url: "http://p/0")
        let lineup = [dead] + (1 ... 8).map { channel("\($0)", "CBS HD", url: "http://p/\($0)") }
        #expect(A.alternates(for: dead, in: lineup, hasRecentlyFailed: never).count == A.limit)
        #expect(A.alternates(for: dead, in: lineup, hasRecentlyFailed: never, limit: 1).count == 1)
        #expect(A.alternates(for: dead, in: lineup, hasRecentlyFailed: never, limit: 0).isEmpty)
    }

    @Test func aLineupWithNoSiblingsYieldsNothingRatherThanAWrongChannel() {
        let dead = channel("1", "CBS", url: "http://p/1")
        #expect(A.alternates(for: dead, in: [dead], hasRecentlyFailed: never).isEmpty)
        #expect(A.alternates(for: dead, in: [], hasRecentlyFailed: never).isEmpty)
    }
}
