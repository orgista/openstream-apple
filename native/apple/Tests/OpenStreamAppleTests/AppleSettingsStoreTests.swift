import Foundation
import MediaAccessibility
import Observation
import SwiftUI
import Synchronization
import Testing
#if os(iOS) || os(tvOS)
import UIKit
#endif
@testable import OpenStreamApple

/// A no-op credential store so settings-store tests never touch the keychain.
private struct StubCredentialStore: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

/// A fresh, isolated `UserDefaults` suite per call so tests cannot leak state
/// through the persisted playback-engine key.
private func makeIsolatedDefaults() -> UserDefaults {
    let name = "openstream.tests.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// The old Player picker's key (and the DEBUG launch argument's name).
private let playbackEngineKey = "openstream.playback.engine"

/// Owner decision 2026-10-01: no Player choice; a "native" the old picker
/// saved is ignored and cleared, and never backed up.
@MainActor
@Test
func aSavedNativeChoiceIsIgnoredAndCleared() {
    let defaults = makeIsolatedDefaults()
    defaults.set("native", forKey: playbackEngineKey)
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.playbackEngine == .openStream)
    #expect(defaults.string(forKey: playbackEngineKey) == nil)
    store.playbackEngine = .native
    #expect(defaults.string(forKey: playbackEngineKey) == nil)
    #expect(!AppleSettingsStore.configurationKeys.contains(playbackEngineKey))
}

@Test
func releaseIgnoresTheNativeLaunchOverride() {
    let args = ["OpenStream", "-openstream.playback.engine", "native"]
    #expect(ApplePlaybackEngineKind.resolved(launchArguments: args, isDebugBuild: false) == .openStream)
    #expect(ApplePlaybackEngineKind.resolved(launchArguments: args, isDebugBuild: true) == .native)
    #expect(ApplePlaybackEngineKind.resolved(launchArguments: ["OpenStream"], isDebugBuild: true) == .openStream)
    #expect(ApplePlaybackEngineKind.resolved(launchArguments: ["-openstream.playback.engine"], isDebugBuild: true)
        == .openStream)
    #expect(ApplePlaybackEngineKind.resolved(launchArguments: ["-openstream.playback.engine", "bogus"],
        isDebugBuild: true) == .openStream)
}

@MainActor
@Test
func playbackEngineDefaultsToOpenStreamWhenUnset() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.playbackEngine == .openStream)
    #expect(defaults.string(forKey: playbackEngineKey) == nil)
}

@MainActor
@Test
func playbackEngineFallsBackToOpenStreamForInvalidStoredValue() {
    let defaults = makeIsolatedDefaults()
    defaults.set("not-a-valid-engine", forKey: playbackEngineKey)

    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.playbackEngine == .openStream)
}

@MainActor
@Test
func factoryReceivesStoredPlaybackEnginePreference() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())

    store.playbackEngine = .native
    let native = ApplePlaybackEngineFactory.make(preferred: store.playbackEngine) {
        FakePlaybackEngine()
    }
    #expect(native.engine.kind == .native)
    #expect(native.fellBack == false)

    store.playbackEngine = .openStream
    let fake = FakePlaybackEngine()
    let preferred = ApplePlaybackEngineFactory.make(preferred: store.playbackEngine) { fake }
    #expect(preferred.engine === (fake as any ApplePlaybackEngine))
    #expect(preferred.fellBack == false)
}

@MainActor
@Test
func engineFellBackToNativeStartsFalseAndIsNotPersisted() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.engineFellBackToNative == false)

    store.engineFellBackToNative = true
    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(reread.engineFellBackToNative == false)
}

/// The persisted key `AppleSettingsStore.captionsPreference` reads and writes.
private let captionsPreferenceKey = "openstream.settings.captions.preference.v1"
private let captionsAutoOnKey = "openstream.settings.captions.autoOn.v1"

@MainActor
@Test
func captionsPreferenceRoundTripsThroughUserDefaults() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    store.captionsPreference = .english

    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(reread.captionsPreference == .english)
    #expect(defaults.string(forKey: captionsPreferenceKey) == "english")
}

/// Deliberate change of intent, 2026-09-15: this asserted `.off`.
///
/// Captions now default to on and the viewer turns them off, rather than
/// defaulting to off behind two settings screens — "auto on captions should be
/// enabled by default but can be toggled off" (owner). `.off` still round-trips
/// once stored, which `captionsPreferenceOffSurvivesAReread` covers.
@MainActor
@Test
func captionsPreferenceDefaultsToOnWhenUnset() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.captionsPreference == .always)
}

/// The half of the owner's ask that is easy to break: turning captions off has
/// to stick, or "on by default" becomes "on always".
@MainActor
@Test
func captionsPreferenceOffSurvivesAReread() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(), systemCaptionsEnabled: { false })
    store.captionsPreference = .off

    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(), systemCaptionsEnabled: { false })
    #expect(reread.captionsPreference == .off)
    #expect(reread.captionsAutoOn == false)
}

@MainActor
@Test
func systemCaptionsEnableWithoutOverwritingTheSavedAppChoice() throws {
    let name = "openstream.tests.caption-system.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("off", forKey: captionsPreferenceKey)
    var systemOn = true
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(),
                                   systemCaptionsEnabled: { systemOn })
    #expect(store.captionsPreference == .always)
    #expect(defaults.string(forKey: captionsPreferenceKey) == "off")
    systemOn = false
    #expect(store.captionsPreference == .off)
    store.captionsPreference = .english
    #expect(store.captionsPreference == .english)
    #expect(defaults.string(forKey: captionsPreferenceKey) == "english")
}

/// Exercise the same projected binding used by the Settings picker, including
/// choosing Off while the system continues to enable captions for playback.
@MainActor
@Test(arguments: AppleCaptionsPreference.allCases)
func captionsPickerKeepsTheStoredChoiceWithSystemCaptionsOn(choice: AppleCaptionsPreference) throws {
    let name = "openstream.tests.caption-picker.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    @Bindable var store = AppleSettingsStore(
        defaults: defaults, keychain: StubCredentialStore(),
        systemCaptionsEnabled: { true }, captionNotificationCenter: NotificationCenter()
    )
    let selection = $store.storedCaptionsPreference
    selection.wrappedValue = choice

    #expect(selection.wrappedValue == choice)
    #expect(store.captionsPreference == (choice == .off ? .always : choice))
    #expect(defaults.string(forKey: captionsPreferenceKey) == choice.rawValue)
    let reread = AppleSettingsStore(
        defaults: defaults, keychain: StubCredentialStore(),
        systemCaptionsEnabled: { true }, captionNotificationCenter: NotificationCenter()
    )
    #expect(reread.storedCaptionsPreference == choice)
}

private var systemCaptionNotificationNames: [Notification.Name] {
    var names = [Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)]
    #if os(iOS) || os(tvOS)
    names.append(UIAccessibility.closedCaptioningStatusDidChangeNotification)
    #endif
    return names
}

@MainActor
@Test(arguments: systemCaptionNotificationNames)
func systemCaptionNotificationInvalidatesEffectivePreference(notification: Notification.Name) async throws {
    let name = "openstream.tests.caption-observation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("off", forKey: captionsPreferenceKey)
    let center = NotificationCenter()
    var systemOn = false
    let store = AppleSettingsStore(
        defaults: defaults, keychain: StubCredentialStore(),
        systemCaptionsEnabled: { systemOn }, captionNotificationCenter: center
    )

    await confirmation("system changes leave the stored choice alone", expectedCount: 0) { storedChanged in
        withObservationTracking {
            _ = store.storedCaptionsPreference
        } onChange: {
            storedChanged()
        }
        for enabled in [true, false] {
            await confirmation("effective preference reader is invalidated") { changed in
                let before = withObservationTracking {
                    store.captionsPreference
                } onChange: {
                    changed()
                }
                #expect(before == (enabled ? .off : .always))
                systemOn = enabled
                center.post(name: notification, object: nil)
                #expect(store.captionsPreference == (enabled ? .always : .off))
                #expect(store.storedCaptionsPreference == .off)
                #expect(defaults.string(forKey: captionsPreferenceKey) == "off")
            }
        }
    }
}

@MainActor
@Test
func captionNotificationsDoNotRetainSettingsStore() {
    let center = NotificationCenter()
    var store: AppleSettingsStore? = AppleSettingsStore(
        defaults: makeIsolatedDefaults(), keychain: StubCredentialStore(),
        systemCaptionsEnabled: { false }, captionNotificationCenter: center
    )
    weak let releasedStore = store
    store = nil
    #expect(releasedStore == nil)
    for name in systemCaptionNotificationNames {
        center.post(name: name, object: nil)
    }
}

@MainActor
@Test
func captionsAutoOnMigratesToAlways() {
    let defaults = makeIsolatedDefaults()
    defaults.set(true, forKey: captionsAutoOnKey)

    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.captionsPreference == .always)
    #expect(store.captionsAutoOn == true)
}

@MainActor @Test func liveTabCanBeHiddenAndRestored() {
    let defaults = makeIsolatedDefaults()
    let settings = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(settings.liveTVEnabled)
    settings.liveTVEnabled = false
    #expect(!AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore()).liveTVEnabled)
    #expect(!OpenStreamTab.visible(liveTVEnabled: false).contains(.live))
    #expect(OpenStreamTab.visible(liveTVEnabled: true).contains(.live))
}

@MainActor @Test func discoverAndLibraryTabsDefaultOnAndPersistIndependently() {
    let defaults = makeIsolatedDefaults()
    let settings = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(settings.discoverEnabled)
    #expect(settings.libraryEnabled)

    settings.discoverEnabled = false
    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(!reread.discoverEnabled)
    #expect(reread.libraryEnabled)
    #expect(reread.liveTVEnabled)

    reread.libraryEnabled = false
    reread.discoverEnabled = true
    let again = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(again.discoverEnabled)
    #expect(!again.libraryEnabled)
}

@Test func visibleTabsFollowTheThreeContentToggles() {
    #expect(
        OpenStreamTabVisibility.visibleTabs(discover: true, library: true, live: true)
            == [.home, .library, .live, .settings]
    )
    #expect(
        OpenStreamTabVisibility.visibleTabs(discover: false, library: true, live: true)
            == [.library, .live, .settings]
    )
    #expect(
        OpenStreamTabVisibility.visibleTabs(discover: false, library: true, live: false)
            == [.library, .settings]
    )
    #expect(
        OpenStreamTabVisibility.visibleTabs(discover: false, library: false, live: true)
            == [.live, .settings]
    )
}

/// Owner 2026-09-14: Search is a bare magnifying glass in the Apple TV tab
/// bar; the word said nothing the glyph did not. Every other tab keeps its
/// title, and Search keeps one as its accessibility label.
@Test func onlySearchDropsItsTitleFromTheTabBar() {
    #expect(!OpenStreamTab.search.showsTitleInTabBar)
    #expect(OpenStreamTab.search.title == "Search")
    for tab in [OpenStreamTab.home, .library, .live, .settings] {
        #expect(tab.showsTitleInTabBar)
    }
}

@Test func hidingTheLastContentTabKeepsIt() {
    // Every toggle off can only come from stored defaults; Discover stays.
    #expect(
        OpenStreamTabVisibility.visibleTabs(discover: false, library: false, live: false)
            == [.home, .settings]
    )

    // The toggle for the only content tab left goes inert.
    #expect(OpenStreamTabVisibility.canToggle(.library, discover: false, library: true, live: false) == false)
    #expect(OpenStreamTabVisibility.canToggle(.live, discover: false, library: false, live: true) == false)
    #expect(OpenStreamTabVisibility.canToggle(.home, discover: true, library: false, live: false) == false)

    // With two or more on, any of them may still be hidden.
    #expect(OpenStreamTabVisibility.canToggle(.home, discover: true, library: true, live: false))
    #expect(OpenStreamTabVisibility.canToggle(.library, discover: true, library: true, live: false))
    #expect(OpenStreamTabVisibility.canToggle(.live, discover: true, library: true, live: true))

    // A tab that is already OFF must always be switchable back ON. This row used
    // to assert the opposite — "a tab that is already off has nothing to hide" —
    // which read correctly against the old name and made the toggle inert, so a
    // tab you switched off could never be switched back on (tester, build 10).
    #expect(OpenStreamTabVisibility.canToggle(.live, discover: true, library: true, live: false))
    #expect(OpenStreamTabVisibility.canToggle(.library, discover: true, library: false, live: true))
    #expect(OpenStreamTabVisibility.canToggle(.home, discover: false, library: true, live: true))
    // Even down to the last one: Library is the only tab on, so the other two
    // must still be reachable.
    #expect(OpenStreamTabVisibility.canToggle(.home, discover: false, library: true, live: false))
    #expect(OpenStreamTabVisibility.canToggle(.live, discover: false, library: true, live: false))

    // Settings is never a candidate.
    #expect(OpenStreamTabVisibility.canToggle(.settings, discover: true, library: true, live: true) == false)
}

@Test func selectionMovesToTheFirstVisibleTabWhenTheCurrentOneIsHidden() {
    let withoutDiscover = OpenStreamTabVisibility.visibleTabs(discover: false, library: true, live: true)
    #expect(OpenStreamTabVisibility.selection(current: .home, visible: withoutDiscover) == .library)
    #expect(OpenStreamTabVisibility.selection(current: .live, visible: withoutDiscover) == .live)
    #expect(OpenStreamTabVisibility.selection(current: .settings, visible: withoutDiscover) == .settings)

    let liveOnly = OpenStreamTabVisibility.visibleTabs(discover: false, library: false, live: true)
    #expect(OpenStreamTabVisibility.selection(current: .library, visible: liveOnly) == .live)

    let everything = OpenStreamTabVisibility.visibleTabs(discover: true, library: true, live: true)
    #expect(OpenStreamTabVisibility.selection(current: .library, visible: everything) == .library)
}

@MainActor @Test func trailerPreferencesDefaultAndPersistIndependently() {
    let defaults = makeIsolatedDefaults()
    let settings = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(settings.autoPlayTrailer)
    #expect(!settings.autoMuteTrailer)
    settings.autoMuteTrailer = true
    settings.autoPlayTrailer = false
    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(!reread.autoPlayTrailer)
    #expect(reread.autoMuteTrailer)
    reread.autoPlayTrailer = true
    #expect(reread.autoMuteTrailer)
}

#if DEBUG
/// Full test 2026-09-30: the dev seed applied the TMDB key and left Use
/// Metadata APIs off.
@MainActor
@Test
func devSeedTMDBKeyTurnsMetadataOn() {
    let store = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: StubCredentialStore())
    #expect(!store.metadataEnabled)
    AppleDevSourcesImport.apply(AppleDevSettings(tmdbAPIKey: "fixture-key"), to: store)
    #expect(store.metadataEnabled)
    #expect(store.tmdbAPIKey == "fixture-key")
}
#endif

@MainActor
@Test func packageDefaultTracksPlaylistWithoutSavingAnExplicitChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lineup = try fixtureLineupStore(directory: directory)
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(), lineupStore: lineup)
    let entries = Array(try fixtureLineup().channels.prefix(20))
    let channels = entries.map {
        AppleIPTVChannel(id: String($0.number), sourceID: UUID(), name: $0.name, group: "All",
                         streamURL: URL(string: "https://fixture.example/channel.ts")!)
    }
    #expect(store.liveChannelPackage == .everything)
    store.updateAutomaticLiveChannelPackage(channels: channels)
    #expect(store.liveChannelPackage == .completeGuide)
    #expect(defaults.string(forKey: "openstream.settings.live.package.v1") == nil)
    store.updateAutomaticLiveChannelPackage(channels: [])
    #expect(store.liveChannelPackage == .everything)
    for choice in AppleLiveChannelPackage.allCases {
        store.liveChannelPackage = choice
        store.updateAutomaticLiveChannelPackage(channels: channels)
        store.updateAutomaticLiveChannelPackage(channels: [])
        #expect(store.liveChannelPackage == choice)
        let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(), lineupStore: lineup)
        #expect(reread.liveChannelPackage == choice)
    }
}

/// A package chosen off the main actor from a guide lineup that has since
/// been replaced never overwrites the choice for the newer one.
@MainActor
@Test func aPackageChosenFromAnOlderGuideLineupIsDropped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lineup = AppleChannelLineupStore(directory: directory)
    let store = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: StubCredentialStore(), lineupStore: lineup)
    let older = try #require(store.automaticLiveChannelPackageInput)
    try lineup.importData(JSONEncoder().encode(fixtureLineup()))
    let newer = try #require(store.automaticLiveChannelPackageInput)
    #expect(store.setAutomaticLiveChannelPackage(.completeGuide, chosenFrom: newer))
    #expect(!store.setAutomaticLiveChannelPackage(.everything, chosenFrom: older))
    #expect(store.liveChannelPackage == .completeGuide)
    lineup.discardAfterReset()
    #expect(!store.setAutomaticLiveChannelPackage(.everything, chosenFrom: newer))
    store.liveChannelPackage = .everything
    #expect(store.automaticLiveChannelPackageInput == nil)
}

@MainActor
@Test func savedLegacyPackageMigratesAndRemainsExplicit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lineup = try fixtureLineupStore(directory: directory)
    let defaults = makeIsolatedDefaults()
    defaults.set("premierGuide", forKey: "openstream.settings.live.package.v1")
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore(), lineupStore: lineup)
    #expect(store.liveChannelPackage == .completeGuide)
    #expect(defaults.string(forKey: "openstream.settings.live.package.v1") == "completeGuide")
    store.updateAutomaticLiveChannelPackage(channels: [])
    #expect(store.liveChannelPackage == .completeGuide)
    let backup = try store.configurationValues()
    try store.restoreConfiguration(backup)
    #expect(store.liveChannelPackage == .completeGuide)
}

/// Owner 2026-10-10: the Apple TV shelf showed only the static image because
/// publishing was off by default and a setup import copied that off value.
@MainActor @Test func topShelfIsOnByDefaultAndIgnoresTheOldOffValue() {
    let defaults = makeIsolatedDefaults()
    defaults.set(false, forKey: "openstream.settings.privacy.topShelf.v1")
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(store.topShelfEnabled)
    #expect(AppleSettingsStore.topShelfEnabled(in: defaults))

    store.showInAppleServices = false
    #expect(!AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore()).topShelfEnabled)
    #expect(!AppleSettingsStore.topShelfEnabled(in: defaults))
}

@MainActor
@Test
func topTenListsRequireAnOptInAndRememberIt() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(!store.top10ListsEnabled)
    store.top10ListsEnabled = true
    #expect(AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore()).top10ListsEnabled)
    store.top10ListsEnabled = false
    #expect(!AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore()).top10ListsEnabled)
}

@MainActor
@Test
func topTenListsRespectStringBooleanPreferencesFromLaunchArguments() {
    let defaults = makeIsolatedDefaults()
    for (value, expected) in [("YES", true), ("true", true), ("1", true), ("NO", false), ("false", false), ("0", false)] {
        defaults.set(value, forKey: "openstream.settings.discover.top10Lists.v1")
        #expect(AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore()).top10ListsEnabled == expected)
    }
}

@MainActor
@Test(arguments: [false, true])
func topTenBooleanPreferenceRemainsExplicitWhenMetadataIsConfigured(enabled: Bool) throws {
    let defaults = makeIsolatedDefaults()
    defaults.set(enabled, forKey: "openstream.settings.discover.top10Lists.v1")
    defaults.set(true, forKey: "openstream.settings.metadata.enabled.v1")
    let keychain = RecordingCredentialStore()
    try keychain.set("fixture-tmdb", for: "metadata.tmdb.apiKey")
    let store = AppleSettingsStore(defaults: defaults, keychain: keychain)
    #expect(store.top10ListsAvailable)
    #expect(store.top10ListsEnabled == enabled)
    #expect(AppleSettingsStore(defaults: defaults, keychain: keychain).top10ListsEnabled == enabled)
}

/// Top 10 rows are TMDB's charts: with no key, or with metadata off, the
/// toggle is unavailable; with both it works.
@MainActor
@Test
func topTenListsNeedATMDBKeyAndMetadata() {
    let store = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: StubCredentialStore())
    store.metadataEnabled = true
    store.tmdbAPIKey = ""
    #expect(!store.top10ListsAvailable)
    store.tmdbAPIKey = "fixture-tmdb"
    #expect(store.top10ListsAvailable)
    store.metadataEnabled = false
    #expect(!store.top10ListsAvailable)
}

/// A link shared before the Keychain gives the TMDB key (a launch before
/// first unlock) waits for it instead of failing.
@MainActor
@Test
func aSharedLinkWaitsForAKeyTheKeychainRefusedAtLaunch() async {
    let keychain = LateCredentialStore()
    let store = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: keychain)
    store.metadataEnabled = true
    #expect(store.tmdbConfiguration == nil)
    keychain.unlocked.withLock { $0 = true }
    #expect(await store.loadedTMDBConfiguration(interval: .milliseconds(1)) != nil)
    #expect(store.tmdbAPIKey == "fixture-tmdb")

    let noKey = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: StubCredentialStore())
    noKey.metadataEnabled = true
    #expect(await noKey.loadedTMDBConfiguration(interval: .seconds(60)) == nil)
}

/// Locked until `unlocked`, then holds a TMDB key.
private final class LateCredentialStore: AppleCredentialStoring {
    let unlocked = Mutex(false)
    func string(for account: String) throws -> String? {
        guard unlocked.withLock({ $0 }) else { throw CocoaError(.fileReadNoPermission) }
        return account == "metadata.tmdb.apiKey" ? "fixture-tmdb" : nil
    }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

/// Records what is stored, so what the store keeps can be seen.
private final class RecordingCredentialStore: AppleCredentialStoring {
    let stored = Mutex<[String: String]>([:])
    var values: [String: String] { stored.withLock { $0 } }
    func string(for account: String) throws -> String? { stored.withLock { $0[account] } }
    func set(_ value: String, for account: String) throws { stored.withLock { $0[account] = value } }
    func remove(_ account: String) throws { stored.withLock { $0[account] = nil } }
}

/// Radarr, Sonarr, Trakt and the transcode gateway left the app (2026-10-22).
/// The app names none of their keys any more: what an old build saved stays
/// unread, and neither a backup nor a restore carries it.
@MainActor
@Test
func retiredServiceSettingsAreNeitherBackedUpNorRestored() throws {
    let defaults = makeIsolatedDefaults()
    let keychain = RecordingCredentialStore()
    defaults.set("https://fixture.example/radarr", forKey: "openstream.settings.radarr.url.v1")
    try keychain.set("fixture-secret", for: "downloads.radarr.apiKey")

    let store = AppleSettingsStore(defaults: defaults, keychain: keychain)
    #expect(try store.configurationValues()["openstream.settings.radarr.url.v1"] == nil)
    #expect(try store.configurationCredentials()["downloads.radarr.apiKey"] == nil)

    let old = try PropertyListSerialization.data(fromPropertyList: ["https://fixture.example/sonarr"], format: .binary, options: 0)
    try store.restoreConfiguration(["openstream.settings.sonarr.url.v1": old])
    try store.restoreConfigurationCredentials(["downloads.sonarr.apiKey": "fixture-sonarr", "metadata.tmdb.apiKey": "test-key"])
    #expect(defaults.object(forKey: "openstream.settings.sonarr.url.v1") == nil)
    #expect(keychain.values["downloads.sonarr.apiKey"] == nil)
    #expect(store.tmdbAPIKey == "test-key")
}

@MainActor @Test
func metadataOffDisablesHeroTMDBRequestsEvenWithAValidKey() async throws {
    let store = AppleSettingsStore(defaults: makeIsolatedDefaults(), keychain: StubCredentialStore())
    store.tmdbAPIKey = "fixture-tmdb"
    store.metadataEnabled = true
    #expect(store.tmdbConfiguration != nil)
    store.metadataEnabled = false
    #expect(store.tmdbConfiguration == nil)
    #expect(await store.loadedTMDBConfiguration(interval: .zero) == nil)
    await confirmation(expectedCount: 0) { requested in
        let client = AppleTMDBClient { _ in
            requested()
            throw AppleTMDBError.titleNotFound
        }
        if let configuration = store.tmdbConfiguration {
            _ = try? await client.details(imdbID: "tt0000072", kind: .movie, configuration: configuration)
        }
    }
}
