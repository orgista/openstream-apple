import Foundation
import Testing
@testable import OpenStreamApple

private final class ScopeCredentialStub: AppleCredentialStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    func string(for reference: String) throws -> String? { values[reference] }
    func set(_ value: String, for reference: String) throws { values[reference] = value }
    func remove(_ reference: String) throws { values[reference] = nil }
}

@Suite struct AppleChannelManagerCleanupTests {
    @Test func liveViewOffersProviderLineupAndMyChannelsOnly() {
        #expect(AppleLiveChannelScope.allCases == [.providerLineup, .favorites])
        #expect(AppleLiveChannelScope(rawValue: "regional") == nil)
        #expect(AppleLiveChannelScope.favorites.title == "My Channels")
    }

    @MainActor @Test func aStoredRegionalScopeFallsBackToTheProviderLineup() {
        let defaults = UserDefaults(suiteName: "scope.\(UUID().uuidString)")!
        defaults.set("regional", forKey: "openstream.settings.live.scope.v1")
        let settings = AppleSettingsStore(defaults: defaults, keychain: ScopeCredentialStub())
        #expect(settings.liveChannelScope == .providerLineup)
    }

    private func channel(_ id: String, _ name: String, group: String) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: UUID(), name: name, group: group, streamURL: URL(string: "https://fixture.example/\(id).m3u8")!)
    }

    @Test func pickerGroupsWhileBrowsingAndFlattensWhileSearching() {
        let lineup = [channel("1", "CBS", group: "NETWORK TV"), channel("2", "ESPN", group: "SPORTS"),
                      channel("3", "ABC", group: "NETWORK TV"), channel("4", "Mystery", group: "")]
        let browsing = AppleChannelPickerSections.build(channels: lineup, query: "")
        #expect(browsing.map(\.name) == ["NETWORK TV", "SPORTS", "Other"])
        #expect(browsing[0].channels.map(\.name) == ["CBS", "ABC"])
        let searching = AppleChannelPickerSections.build(channels: [lineup[0]], query: "cb")
        #expect(searching.map(\.name) == ["Results"])
        #expect(AppleChannelPickerSections.build(channels: [], query: "").isEmpty)
    }
}
