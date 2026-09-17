import Foundation
import Testing
@testable import OpenStreamApple

@Test func liveSnapshotKeepsCategoriesFavoritesAndChannelIDsConsistent() throws {
    let source = UUID()
    let channels = [
        AppleIPTVChannel(id: "news", sourceID: source, name: "CNN HD", group: "News", streamURL: URL(string: "https://fixture.example/news.ts")!),
        AppleIPTVChannel(id: "sports", sourceID: source, name: "ESPN (EAST)", group: "Sports", streamURL: URL(string: "https://fixture.example/sports.ts")!)
    ]
    let entries = try AppleChannelLineupPresets.premierUS()
    let snapshot = AppleLiveChannelSnapshot.build(groups: [.init(name: "All", channels: channels)],
        package: .everything, custom: .init(), entries: entries, favoriteIDs: ["sports"], category: "Favorites")
    #expect(snapshot.channels.map(\.id) == ["sports"])
    #expect(snapshot.channelIDs == ["sports"])
    #expect(snapshot.categories.contains("News"))
    #expect(snapshot.categories.contains("Sports"))
    let all = AppleLiveChannelSnapshot.build(groups: [.init(name: "All", channels: channels)],
        package: .everything, custom: .init(), entries: entries, favoriteIDs: [], category: "All")
    #expect(Set(all.channelIDs) == ["news", "sports"])
}

/// Owner 2026-09-14: "reduce the live line up to the premier safe thing we did
/// with iPhone and android". `premierGuideGroups` returns the curated lineup
/// *and* an "Other" group of everything it could not match, and the guide was
/// flattening both — 4749 of the owner's 9376 channels reached the grid.
@Suite("Premier Guide lineup")
struct ApplePremierGuideLineupTests {
    private let source = UUID()

    private func channel(_ id: String, _ name: String) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: source, name: name, group: "All",
                         streamURL: URL(string: "https://fixture.example/\(id).ts")!)
    }

    /// Eight networks — `AppleLiveChannelSnapshot.minimumLineupMatches` — so
    /// the lineup is trusted. It used to be two, which is exactly the
    /// coincidence-not-a-guide case a tester hit on build 10, and the test was
    /// asserting the bug.
    private let networks = ["CBS", "FOX", "NBC", "ABC", "CW", "PBS", "ION", "MyTV"]

    private var lineup: [AppleChannelLineupEntry] {
        networks.enumerated().map { index, name in
            AppleChannelLineupEntry(number: index + 2, name: name, aliases: ["\(name) (EAST)"], category: "Local")
        }
    }

    private var curatedIDs: [String] { networks.map { $0.lowercased() } }

    private var channels: [AppleIPTVChannel] {
        networks.map { channel($0.lowercased(), "\($0) (EAST)") }
            + [channel("rando1", "PPV Barker 14"), channel("rando2", "24/7 Kitchen Nightmares")]
    }

    @Test func allShowsOnlyTheCuratedLineup() {
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: channels)], package: .premierGuide,
            custom: .init(), entries: lineup, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs == curatedIDs)
    }

    @Test func everythingStillShowsEverything() {
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: channels)], package: .everything,
            custom: .init(), entries: lineup, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == channels.count)
    }

    /// An empty guide would be worse than an unfiltered one.
    @Test func aLineupThatMatchesNothingFallsBackToTheChannelsWeHave() {
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: channels)], package: .premierGuide,
            custom: .init(), entries: [], favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == channels.count)
    }

    /// Tester, build 10: "in the live tv tab -> All, only one TV channel is
    /// displayed in M3U". The fallback fired only when the lineup matched
    /// nothing at all, so a foreign playlist with one channel that happened to
    /// share a name with the US lineup showed exactly that one channel.
    @Test func oneAccidentalLineupMatchDoesNotHideTheRestOfThePlaylist() {
        // Forty channels no US lineup knows, plus one that collides on "CBS".
        var foreign = (1...40).map { channel("ch\($0)", "Kanal \($0)") }
        foreign.append(channel("collision", "CBS"))
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: foreign)], package: .premierGuide,
            custom: .init(), entries: lineup, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == 41, "one coincidental match hid \(41 - snapshot.channelIDs.count) channels")
    }

    /// The floor is a floor: at it, the lineup is trusted and All stays curated.
    @Test func atTheFloorTheLineupIsTrusted() {
        let floor = AppleLiveChannelSnapshot.minimumLineupMatches
        let entries = (1...floor).map {
            AppleChannelLineupEntry(number: $0, name: "Net \($0)", aliases: [], category: "Entertainment")
        }
        var list = (1...floor).map { channel("net\($0)", "Net \($0)") }
        list += (1...20).map { channel("x\($0)", "Unrelated \($0)") }
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: list)], package: .premierGuide,
            custom: .init(), entries: entries, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == floor, "at the floor All should be the curated \(floor), got \(snapshot.channelIDs.count)")
    }

    /// One under the floor and it is a coincidence, not a guide.
    @Test func oneUnderTheFloorShowsEverything() {
        let floor = AppleLiveChannelSnapshot.minimumLineupMatches
        let entries = (1..<floor).map {
            AppleChannelLineupEntry(number: $0, name: "Net \($0)", aliases: [], category: "Entertainment")
        }
        var list = (1..<floor).map { channel("net\($0)", "Net \($0)") }
        list += (1...20).map { channel("x\($0)", "Unrelated \($0)") }
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: list)], package: .premierGuide,
            custom: .init(), entries: entries, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == list.count)
    }

    @Test func favoritesAreNotLimitedToTheLineup() {
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: channels)], package: .premierGuide,
            custom: .init(), entries: lineup, favoriteIDs: ["rando1"], category: "Favorites")
        #expect(snapshot.channelIDs == ["rando1"])
    }
}


/// Owner, 2026-09-17: "no one ever needs 3k channels… note to the user if they
/// try to add more than 300 they reached the limit." The guide stops at 300 and
/// reports what it kept back, so the Live tab can say so in one line.
@Suite("Display cap")
struct AppleLiveChannelDisplayCapTests {
    private let source = UUID()
    private func channel(_ i: Int) -> AppleIPTVChannel {
        AppleIPTVChannel(id: "c\(i)", sourceID: source, name: "Channel \(i)", group: "All",
                         streamURL: URL(string: "https://fixture.example/\(i).ts")!)
    }
    private func snapshot(_ n: Int, category: String = "All", favorites: Set<String> = []) -> AppleLiveChannelSnapshot {
        AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: (1...n).map(channel))], package: .everything,
            custom: .init(), entries: [], favoriteIDs: favorites, category: category)
    }

    @Test func theCapIsThreeHundred() {
        #expect(AppleLiveChannelSnapshot.maximumDisplayedChannels == 300)
    }

    @Test func atTheCapNothingIsHidden() {
        let s = snapshot(300)
        #expect(s.channels.count == 300); #expect(s.hiddenCount == 0)
    }

    @Test func oneOverTheCapHidesExactlyOneAndSaysSo() {
        let s = snapshot(301)
        #expect(s.channels.count == 300, "drew \(s.channels.count)")
        #expect(s.hiddenCount == 1)
        #expect(s.channelIDs.count == 300, "channelIDs must match what is drawn")
    }

    @Test func aBigProviderReportsTheWholeRemainder() {
        let s = snapshot(9_376)
        #expect(s.channels.count == 300); #expect(s.hiddenCount == 9_076)
    }

    @Test func aSmallPlaylistIsUntouched() {
        let s = snapshot(28)
        #expect(s.channels.count == 28); #expect(s.hiddenCount == 0)
    }

    /// Channel Manager may add up to the cap and not one past it.
    @Test func theThreeHundredAndFirstAddIsRefused() {
        #expect(AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: 0))
        #expect(AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: 299))
        #expect(!AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: 300))
        #expect(!AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: 9_376))
        #expect(AppleLiveChannelSnapshot.limitReachedMessage.contains("300"))
    }

    /// Favorites is its own list and is capped on its own numbers, not the
    /// provider's: 5 favourites out of 9,376 channels are all shown.
    @Test func favoritesAreCappedOnTheirOwnCount() {
        let favs: Set<String> = ["c1", "c2", "c3", "c4", "c5"]
        let s = snapshot(9_376, category: "Favorites", favorites: favs)
        #expect(s.channels.count == 5); #expect(s.hiddenCount == 0)
    }
}
