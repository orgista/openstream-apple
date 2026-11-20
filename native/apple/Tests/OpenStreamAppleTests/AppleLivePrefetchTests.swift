import Foundation
import Testing
@testable import OpenStreamApple

/// The launch prefetch warms the channels Live draws first (owner 2026-10-22).
struct AppleLivePrefetchTests {
    private static let source = UUID()

    private static func channel(_ number: Int, logo: Bool = true) -> AppleIPTVChannel {
        AppleIPTVChannel(id: "\(source.uuidString):\(number)", sourceID: source, name: "Channel \(number)",
                         logoURL: logo ? URL(string: "https://fixture.example/logo/\(number).png") : nil,
                         streamURL: URL(string: "https://fixture.example/live/\(number).ts")!)
    }

    private static let lineup = (1...250).map { channel($0) }

    @Test func theFirstTwoScreensInPlaylistOrder() {
        let leading = AppleLivePrefetch.leadingChannels(Self.lineup, preferredIDs: [], hiddenIDs: [])
        #expect(leading.count == AppleLivePrefetch.leadingCount)
        #expect(leading.map(\.id) == Self.lineup.prefix(AppleLivePrefetch.leadingCount).map(\.id))
    }

    @Test func watchedAndFavouriteChannelsComeFirstOnce() {
        let watched = Self.lineup[199].id, favourite = Self.lineup[149].id
        let leading = AppleLivePrefetch.leadingChannels(Self.lineup,
            preferredIDs: [watched, favourite, watched, "gone"], hiddenIDs: [], limit: 4)
        #expect(leading.map(\.id) == [watched, favourite, Self.lineup[0].id, Self.lineup[1].id])
    }

    @Test func hiddenChannelsAreSkippedEvenWhenFavourite() {
        let hidden = Self.lineup[0].id
        let leading = AppleLivePrefetch.leadingChannels(Self.lineup, preferredIDs: [hidden],
                                                        hiddenIDs: [hidden], limit: 2)
        #expect(leading.map(\.id) == [Self.lineup[1].id, Self.lineup[2].id])
    }

    /// With an imported lineup Live sorts by its numbers, so the warm set
    /// follows them; channels the lineup does not know keep playlist order.
    @Test func anImportedLineupOrdersTheLeadingChannels() {
        let entries = [AppleChannelLineupEntry(number: 2, name: "Channel 200", aliases: [], category: "News"),
                       AppleChannelLineupEntry(number: 5, name: "Channel 3", aliases: [], category: "Sports")]
        let leading = AppleLivePrefetch.leadingChannels(Self.lineup, preferredIDs: [Self.lineup[9].id],
                                                        hiddenIDs: [], entries: entries, limit: 5)
        #expect(leading.map(\.id) == [9, 199, 2, 0, 1].map { Self.lineup[$0].id })
    }

    @Test func logosAreRequestedAtTheRowsSize() {
        let requests = AppleLivePrefetch.logoRequests([Self.channel(1), Self.channel(2, logo: false)], displayScale: 3)
        #expect(requests.map(\.url) == [URL(string: "https://fixture.example/logo/1.png")!])
        // A 50 pt logo at 3x decodes into the 256 px bucket, as the row's own view does.
        #expect(requests.map(\.maximumPixelDimension) == [256])
    }

    /// The guide setup now runs at every launch: a playlist that lists one
    /// channel id twice must not trap (`Dictionary(uniqueKeysWithValues:)` did).
    @MainActor @Test func guideSetupTakesDuplicateChannelIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "live-prefetch-duplicates-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = AppleSourceStore(defaults: defaults, keychain: PrefetchTestCredentials(),
                                       documentsDirectory: root.appendingPathComponent("documents"))
        let source = try sources.addIPTV(name: "Fixture TV", type: .m3u,
            endpoint: "https://fixture.example/channels.m3u", username: "", password: "")
        let settings = AppleSettingsStore(defaults: defaults, keychain: PrefetchTestCredentials())
        func channel(_ name: String, shift: Double) -> AppleIPTVChannel {
            var channel = AppleIPTVChannel(id: "\(source.id.uuidString):dup", sourceID: source.id, name: name,
                streamURL: URL(string: "https://fixture.example/live/\(name).ts")!, guideID: "guide.\(name)")
            channel.guideShiftHours = shift
            return channel
        }
        let guide = AppleIPTVGuideStore()
        guide.configure(liveSources: [source], channels: [channel("First", shift: 1), channel("Second", shift: 2)],
                        sourceStore: sources, settings: settings)
        #expect(guide.channelDisplayNames == ["\(source.id.uuidString):dup": "First"])
        #expect(guide.channelProviderIDs == ["\(source.id.uuidString):dup": "guide.First"])
    }

    /// The Live tab configures again until every panel's Keychain item was read.
    @MainActor @Test func guideSetupReportsAPanelWithoutItsKeychainItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "live-prefetch-keychain-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = AppleSourceStore(defaults: defaults, keychain: PrefetchTestCredentials(),
                                       documentsDirectory: root.appendingPathComponent("documents"))
        let settings = AppleSettingsStore(defaults: defaults, keychain: PrefetchTestCredentials())
        let playlist = try sources.addIPTV(name: "Fixture TV", type: .m3u,
            endpoint: "https://fixture.example/channels.m3u", username: "", password: "")
        let panel = try sources.addIPTV(name: "Fixture Panel", type: .xtream,
            endpoint: "https://panel.fixture.example", username: "viewer", password: "fixture")
        let guide = AppleIPTVGuideStore()
        #expect(guide.configure(liveSources: [playlist], channels: [], sourceStore: sources, settings: settings))
        #expect(!guide.configure(liveSources: [playlist, panel], channels: [], sourceStore: sources, settings: settings))
    }
}

private struct PrefetchTestCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

/// The Live tab configures its guide only when an input of `configure` changed.
@MainActor
struct AppleLiveGuideConfigurationTests {
    private let source = AppleSource(kind: .liveTV, name: "Panel", url: URL(string: "https://panel.fixture.example")!,
                                     iptvType: .xtream, credentialReference: "panel")

    private func key(_ sources: [AppleSource]? = nil, revision: Int = 1, offsets: [String: Int] = [:],
                     assignments: [String: String] = [:]) -> String {
        AppleLiveGuideConfiguration.key(sources: sources ?? [source], channelsRevision: revision,
                                        timeOffsets: offsets, assignments: assignments)
    }

    @Test func anUnchangedKeySkipsAndForceAlwaysConfigures() {
        let gate = AppleLiveGuideConfiguration()
        #expect(gate.needsConfigure(key(), force: false))
        gate.didConfigure(key(), complete: true)
        #expect(!gate.needsConfigure(key(), force: false))
        #expect(gate.needsConfigure(key(), force: true))
        #expect(gate.needsConfigure(key(revision: 2), force: false))
    }

    @Test func aMissedKeychainItemIsReadAgain() {
        let gate = AppleLiveGuideConfiguration()
        gate.didConfigure(key(), complete: false)
        #expect(gate.needsConfigure(key(), force: false))
    }

    @Test func everyInputChangesTheKey() {
        var edited = source
        edited.configurationRevision += 1
        var guide = source
        guide.epgURL = URL(string: "https://guide.fixture.example/epg.xml")
        var moved = source
        moved.url = URL(string: "https://other.fixture.example")!
        var credentials = source
        credentials.credentialReference = "other"
        var signIn = source
        signIn.needsSignIn = true
        var disabled = source
        disabled.isEnabled = false
        let keys = [key(), key([edited]), key([guide]), key([moved]), key([credentials]), key([signIn]), key([disabled]),
                    key([]), key(revision: 2), key(offsets: [source.id.uuidString: 1]), key(assignments: ["a": "b"])]
        #expect(Set(keys).count == keys.count)
    }
}
