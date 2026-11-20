import Foundation
import SwiftUI
import Testing
@testable import OpenStreamApple

@MainActor
struct ApplePlayerHostLifetimeTests {
    @Test func rebuildingPlayerValuesDoesNotActivateDiscardedHosts() throws {
        let name = "player-host-lifetime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: HostLifetimeCredentials())
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/movie.mp4")),
                                           mediaID: "host-lifetime", sourceKind: .files)
        let presentation = AppleMediaPlayerPresentation(request: request, settings: settings, engineOverride: .native)
        let engine = FakePlaybackEngine()
        presentation.coordinator.adoptEngine(engine)
        defer { presentation.coordinator.stop() }
        let reads = engine.avPlayerReadCount
        for _ in 0..<4 {
            _ = AppleMediaPlayerView(presentation: presentation)
        }
        #expect(engine.avPlayerReadCount == reads)
    }
}

private final class HostLifetimeCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}
