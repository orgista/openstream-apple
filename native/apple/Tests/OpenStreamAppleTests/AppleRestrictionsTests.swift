import Foundation
import Testing
@testable import OpenStreamApple

struct AppleRestrictionsTests {
    @Test(arguments: ["", "123", "12345", "12a4", "١٢٣٤", " 1234"])
    func rejectsInvalidPIN(_ value: String) { #expect(AppleRestrictionPolicy.validPIN(value) == false) }
    @Test func acceptsExactlyFourASCIIDigits() { #expect(AppleRestrictionPolicy.validPIN("0123")) }
    @Test func channelAndGroupLocksSharePolicy() {
        var policy = AppleRestrictionPolicy()
        policy.channelIDs = ["locked"]
        policy.groups = ["Adult"]
        #expect(policy.isLocked(channelID: "locked", group: "News"))
        #expect(policy.isLocked(channelID: "other", group: "Adult"))
        #expect(policy.isLocked(channelID: "other", group: "News") == false)
        policy.hideLocked = true
        #expect(policy.isVisible(channelID: "locked", group: "News", hasPIN: true) == false)
        #expect(policy.isVisible(channelID: "locked", group: "News", hasPIN: false))
    }
    @MainActor @Test func correctPINUnlocksOnlyUntilBackgroundAndResetClearsLists() throws {
        let name = "restrictions-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = PINMemory()
        let store = AppleRestrictionStore(defaults: defaults, credentials: credentials)
        try store.setPIN("0123")
        store.update { $0.channelIDs = ["locked"]; $0.groups = ["Adult"]; $0.lockSettings = true }
        store.background()
        #expect(store.needsUnlock(channelID: "locked", group: "News"))
        #expect(store.submit("9999") == false)
        #expect(store.sessionUnlocked == false)
        #expect(store.submit("0123"))
        #expect(store.needsUnlock(channelID: "locked", group: "News") == false)
        store.background()
        #expect(store.sessionUnlocked == false)
        let restored = AppleRestrictionStore(defaults: defaults, credentials: credentials)
        #expect(restored.hasPIN)
        #expect(restored.policy.channelIDs == ["locked"])
        try restored.removeRestrictions()
        #expect(restored.hasPIN == false)
        #expect(restored.policy == AppleRestrictionPolicy())
        #expect(credentials.value == nil)
    }
    @MainActor @Test func cancellingGateDoesNotUnlock() async throws {
        let name = "restrictions-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppleRestrictionStore(defaults: defaults, credentials: PINMemory())
        try store.setPIN("1234")
        store.update { $0.channelIDs = ["locked"] }
        store.background()
        let task = Task { await store.authorize(channelID: "locked", group: "", title: "Locked") }
        while store.prompt == nil { await Task.yield() }
        store.cancelPrompt()
        #expect(await task.value == false)
        #expect(store.sessionUnlocked == false)
    }
    @Test func catchUpRetainsChannelRestrictionIdentity() {
        var channel = AppleIPTVChannel(id: "channel", sourceID: UUID(), name: "Channel", group: "Adult", streamURL: URL(string: "https://fixture.example/live.m3u8")!)
        channel.catchUp = AppleIPTVCatchUpSpec(style: .default, source: "https://fixture.example/archive/{utc}.m3u8")
        let programme = AppleIPTVProgramme(id: "show", channelID: channel.id, title: "Show", subtitle: nil, description: nil, start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60), category: nil, isLive: false)
        #expect(channel.playbackRequest().restrictionGroup == "Adult")
        let request = AppleIPTVCatchUp.playbackRequest(for: channel, programme: programme)
        #expect(request?.restrictionChannelID == channel.id)
        #expect(request?.restrictionGroup == "Adult")
    }
}

private final class PINMemory: AppleCredentialStoring {
    var value: String?
    func string(for account: String) throws -> String? { value }
    func set(_ value: String, for account: String) throws { self.value = value }
    func remove(_ account: String) throws { value = nil }
}
