import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Test func customPackageStartsWithEastFeedAndPersistsChannelAndGroupOverrides() throws {
    let source = UUID()
    func channel(_ id: String, _ name: String, _ group: String = "News") -> AppleIPTVChannel {
        .init(id: id, sourceID: source, name: name, group: group, streamURL: URL(string: "https://tv.example/\(id)")!)
    }
    let values = [channel("east", "CBS (EAST)"), channel("west", "CBS (WEST)"), channel("empty", "MAX USA 15: NO EVENT", "Events")]
    var package = AppleCustomChannelPackage()
    #expect(package.selected(from: values).map(\.id) == ["east"])
    package.includeWestFeeds = true
    package.channels["east"] = false
    package.channels["empty"] = true
    #expect(package.selected(from: values).map(\.id) == ["west", "empty"])
    package.groups["News"] = false
    #expect(package.selected(from: values).map(\.id) == ["empty"])
    let suite = "custom-package-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppleSettingsStore(defaults: defaults, keychain: CustomPackageCredentialStub())
    settings.customChannelPackage = package
    #expect(AppleSettingsStore(defaults: defaults, keychain: CustomPackageCredentialStub()).customChannelPackage == package)
}

private struct CustomPackageCredentialStub: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
