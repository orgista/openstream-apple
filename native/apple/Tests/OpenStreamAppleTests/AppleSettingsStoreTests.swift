import Foundation
import MediaAccessibility
import Observation
import SwiftUI
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
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    let entries = Array(try AppleChannelLineupPresets.completeUS().prefix(20))
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
        let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
        #expect(reread.liveChannelPackage == choice)
    }
}

@MainActor
@Test func savedLegacyPackageMigratesAndRemainsExplicit() throws {
    let defaults = makeIsolatedDefaults()
    defaults.set("premierGuide", forKey: "openstream.settings.live.package.v1")
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
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
