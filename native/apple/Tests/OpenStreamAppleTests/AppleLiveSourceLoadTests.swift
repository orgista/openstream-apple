import Foundation
import Testing
@testable import OpenStreamApple

/// iPad v2 re-run (2026-10-01): one dead IPTV panel held the Live tab for
/// ~35 s. Playlists now load at once and show as each answers.
struct AppleLiveSourceLoadTests {
    private let dead = AppleSource(kind: .liveTV, name: "Dead Panel", url: URL(string: "https://dead.fixture.example")!, iptvType: .xtream)
    private let healthy = AppleSource(kind: .liveTV, name: "Fixture", url: URL(string: "https://live.fixture.example")!, iptvType: .m3u)

    private func channel(_ name: String, source: AppleSource) -> AppleIPTVChannel {
        AppleIPTVChannel(id: "\(source.id)-\(name)", sourceID: source.id, name: name,
                         streamURL: URL(string: "http://127.0.0.1/fixture.mp4")!)
    }

    @Test func aHealthyPlaylistShowsBeforeTheDeadOneAnswers() {
        var load = AppleLiveSourceLoad(sources: [dead, healthy])
        load.succeeded(healthy.id, channels: [channel("One", source: healthy)])
        #expect(load.channels.map(\.name) == ["One"])
        #expect(load.isComplete == false)
        #expect(load.failures.isEmpty)
    }

    @Test func aFailedPlaylistReportsItsErrorAndRetainsItsSavedChannels() {
        var load = AppleLiveSourceLoad(sources: [dead, healthy], cached: [dead.id: [channel("Old", source: dead)]])
        #expect(load.channels.map(\.name) == ["Old"])
        load.succeeded(healthy.id, channels: [channel("One", source: healthy)])
        load.failed(dead.id, message: "The request timed out.")
        #expect(load.channels.map(\.name) == ["Old", "One"])
        #expect(load.failures.map(\.text) == ["Dead Panel: The request timed out."])
        #expect(load.isComplete)
    }

    @Test func aSuccessfulEmptyRefreshReplacesTheSavedLineup() {
        var load = AppleLiveSourceLoad(sources: [dead], cached: [dead.id: [channel("Old", source: dead)]])
        load.failed(dead.id, message: "Offline")
        #expect(load.channels.map(\.name) == ["Old"])
        load.succeeded(dead.id, channels: [])
        #expect(load.channels.isEmpty)
        #expect(load.failures.isEmpty)
        #expect(load.isComplete)
    }

    @Test func channelsKeepTheOrderTheSourcesWereAdded() {
        var load = AppleLiveSourceLoad(sources: [dead, healthy])
        load.succeeded(healthy.id, channels: [channel("Second", source: healthy)])
        load.succeeded(dead.id, channels: [channel("First", source: dead)])
        #expect(load.channels.map(\.name) == ["First", "Second"])
    }

    /// Owner 2026-10-08: a refresh that failed under a working saved lineup
    /// put a warning row over it. Only a playlist with nothing on screen is
    /// worth a word.
    @Test func aFailureUnderSavedChannelsIsMarkedSoTheTabStaysQuiet() {
        var load = AppleLiveSourceLoad(sources: [dead, healthy], cached: [dead.id: [channel("Old", source: dead)]])
        load.failed(dead.id, message: "Could not connect to the server.")
        load.failed(healthy.id, message: "The request timed out.")
        #expect(load.failures.map(\.showsSavedChannels) == [true, false])
        #expect(load.channels.map(\.name) == ["Old"])
    }

    private struct Unreachable: Error {}

    @Test @MainActor func eachAnswerPublishesOnceAndThePackageOnlyComesFromTheWholeLineup() async {
        let late = AppleSource(kind: .liveTV, name: "Late", url: URL(string: "https://late.fixture.example")!, iptvType: .m3u)
        var load = AppleLiveSourceLoad(sources: [healthy, dead, late], cached: [dead.id: [channel("Saved", source: dead)]])
        var publications: [AppleLiveSourceLoad.Publication] = []
        let fetched = [healthy.id: [channel("One", source: healthy)], late.id: [channel("Two", source: late)]]
        let finished = await AppleLiveSourceLoad.collect([healthy, dead, late], fetch: { source in
            (source, fetched[source.id].map { .success($0) } ?? .failure(Unreachable()))
        }, answer: { source, result in
            switch result {
            case .success(let channels): load.succeeded(source.id, channels: channels)
            case .failure: load.failed(source.id, message: "Offline")
            }
            return true
        }, publish: {
            publications.append(await load.publication(packageEntries: []))
        })
        #expect(finished)
        #expect(publications.count == 3)
        #expect(publications.last?.index.channels.map(\.name) == ["One", "Saved", "Two"])
        #expect(publications.last?.package != nil)
        #expect(publications.filter { $0.package != nil }.allSatisfy { $0.index.channels.map(\.name) == ["One", "Saved", "Two"] })
    }

    @Test func aPlaylistStillOutKeepsThePackageAndAnUnsavedFailureCompletesIt() async {
        var load = AppleLiveSourceLoad(sources: [healthy, dead])
        load.succeeded(healthy.id, channels: [channel("One", source: healthy)])
        let partial = await load.publication(packageEntries: [])
        #expect(load.unanswered == [dead.id])
        #expect(partial.index.channels.map(\.name) == ["One"])
        #expect(partial.package == nil)
        load.failed(dead.id, message: "Offline")
        let whole = await load.publication(packageEntries: [])
        #expect(load.unanswered.isEmpty)
        #expect(whole.package == AppleLiveChannelPackage.defaultPackage(for: whole.index.channels, entries: []))
    }

    @Test func aPickedPackageIsNotReplaced() async {
        var load = AppleLiveSourceLoad(sources: [healthy])
        load.succeeded(healthy.id, channels: [channel("One", source: healthy)])
        #expect(await load.publication(packageEntries: nil).package == nil)
    }

    @Test @MainActor func nothingToAskPublishesOnce() async {
        var published = 0
        let finished = await AppleLiveSourceLoad.collect([AppleSource](), fetch: { source in (source, .success([])) },
            answer: { _, _ in true }, publish: { published += 1 })
        #expect(finished)
        #expect(published == 1)
    }

    @Test @MainActor func aStoppedAnswerEndsTheRunWithoutPublishing() async {
        var published = 0
        let finished = await AppleLiveSourceLoad.collect([healthy], fetch: { source in (source, .failure(CancellationError())) },
            answer: { _, _ in false }, publish: { published += 1 })
        #expect(finished == false)
        #expect(published == 0)
    }
}
