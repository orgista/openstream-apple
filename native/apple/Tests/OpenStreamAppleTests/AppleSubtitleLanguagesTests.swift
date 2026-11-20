import Foundation
import Testing
@testable import OpenStreamApple

private struct InMemoryCredentialStore: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

@Test func subtitleLanguageNormalizationAcceptsCommonShapes() {
    #expect(AppleSubtitleLanguages.normalized("en") == "eng")
    #expect(AppleSubtitleLanguages.normalized("eng") == "eng")
    #expect(AppleSubtitleLanguages.normalized("pt-BR") == "por")
    #expect(AppleSubtitleLanguages.normalized("English") == "eng")
    #expect(AppleSubtitleLanguages.normalized("  ES  ") == "spa")
    #expect(AppleSubtitleLanguages.normalized("fre") == "fra")
    #expect(AppleSubtitleLanguages.normalized("zz-quux") == nil)
    #expect(AppleSubtitleLanguages.normalized("") == nil)
}

@Test func subtitleLanguageDefaultIsTheDevicesPrimaryLanguage() {
    let defaults = AppleSubtitleLanguages.deviceDefaults(
        preferredLanguages: ["en-US", "es-MX", "en-GB", "fr-FR", "de-DE"]
    )
    #expect(defaults == ["eng"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["es-MX", "en-US"]) == ["spa"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["qq", "fr-FR"]) == ["fra"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["en-US"]) == ["eng"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["qq"]) == ["eng"])
}

@Test func subtitleLanguageSelectionStopsAtThree() {
    var selection: [String] = []
    for code in ["en", "spa", "fra", "deu"] {
        selection = AppleSubtitleLanguages.toggling(code, in: selection)
    }
    #expect(selection == ["eng", "spa", "fra"])

    selection = AppleSubtitleLanguages.toggling("spa", in: selection)
    #expect(selection == ["eng", "fra"])

    selection = AppleSubtitleLanguages.toggling("deu", in: selection)
    #expect(selection == ["eng", "fra", "deu"])

    #expect(AppleSubtitleLanguages.sanitized(["en", "eng", "pt-BR", "zz", "ita"]) == ["eng", "por", "ita"])
}

@MainActor
@Test func subtitleLanguagesRoundTripThroughUserDefaults() {
    let suite = "openstream.tests.subtitleLanguages.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)

    let store = AppleSettingsStore(defaults: defaults, keychain: InMemoryCredentialStore())
    #expect(store.hasChosenSubtitleLanguages == false)

    store.subtitleLanguages = ["en", "pt-BR", "zz", "ita", "fra"]
    #expect(store.subtitleLanguages == ["eng", "por", "ita"])

    let reread = AppleSettingsStore(defaults: defaults, keychain: InMemoryCredentialStore())
    #expect(reread.subtitleLanguages == ["eng", "por", "ita"])
    #expect(reread.hasChosenSubtitleLanguages)
}
