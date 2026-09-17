import Foundation
import Testing
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

/// The persisted key `AppleSettingsStore.playbackEngine` reads and writes, so
/// tests can write an invalid raw value directly and assert the store maps it
/// back to the default.
private let playbackEngineKey = "openstream.playback.engine"

@MainActor
@Test
func playbackEngineRoundTripsThroughUserDefaults() {
    let defaults = makeIsolatedDefaults()
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    store.playbackEngine = .native

    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(reread.playbackEngine == .native)
    #expect(defaults.string(forKey: playbackEngineKey) == "native")
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
    let store = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    store.captionsPreference = .off

    let reread = AppleSettingsStore(defaults: defaults, keychain: StubCredentialStore())
    #expect(reread.captionsPreference == .off)
    #expect(reread.captionsAutoOn == false)
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
