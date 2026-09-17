import Foundation
import Testing
@testable import OpenStreamApple

private struct InMemoryCredentialStore: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

private func track(_ language: String, source: String = "Add-on") -> AppleExternalSubtitleTrack {
    AppleExternalSubtitleTrack(
        id: "\(source):\(language)",
        languageCode: language,
        sourceName: source,
        url: URL(string: "https://example.test/\(language).srt")!
    )
}

@Test func subtitleLanguageNormalizationAcceptsTheShapesAddOnsSend() {
    #expect(AppleSubtitleLanguages.normalized("en") == "eng")
    #expect(AppleSubtitleLanguages.normalized("eng") == "eng")
    #expect(AppleSubtitleLanguages.normalized("pt-BR") == "por")
    #expect(AppleSubtitleLanguages.normalized("English") == "eng")
    #expect(AppleSubtitleLanguages.normalized("  ES  ") == "spa")
    #expect(AppleSubtitleLanguages.normalized("fre") == "fra")
    #expect(AppleSubtitleLanguages.normalized("zz-quux") == nil)
    #expect(AppleSubtitleLanguages.normalized("") == nil)
}

@Test func subtitleLanguageDefaultsAreEnglishFirstThenTheDeviceLanguages() {
    let defaults = AppleSubtitleLanguages.deviceDefaults(
        preferredLanguages: ["en-US", "es-MX", "en-GB", "fr-FR", "de-DE"]
    )
    #expect(defaults == ["eng", "spa", "fra"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["es-MX"]) == ["eng", "spa"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["en-US"]) == ["eng"])
    #expect(AppleSubtitleLanguages.deviceDefaults(preferredLanguages: ["qq"]) == ["eng"])
}

@Test func subtitlesRowIsOfferedOnlyForManifestsThatDeclareSubtitles() {
    #expect(AppleSubtitleLanguages.declaresSubtitles(resources: ["catalog", "subtitles"]))
    #expect(AppleSubtitleLanguages.declaresSubtitles(resources: [" Subtitles "]))
    #expect(AppleSubtitleLanguages.declaresSubtitles(resources: ["catalog", "meta", "stream"]) == false)
    #expect(AppleSubtitleLanguages.declaresSubtitles(resources: []) == false)
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

@Test func externalSubtitleFilterKeepsPreferenceOrderAndDropsOtherLanguages() {
    let tracks = [track("fre"), track("eng"), track("spa"), track("deu")]
    let filtered = AppleExternalSubtitleService.filtered(tracks, preferredLanguages: ["spa", "eng"])
    #expect(filtered.map(\.languageCode) == ["spa", "eng"])
}

@Test func externalSubtitleFilterKeepsEverythingWhenNoLanguageIsPreferred() {
    let tracks = [track("eng"), track("deu")]
    let filtered = AppleExternalSubtitleService.filtered(tracks, preferredLanguages: [])
    #expect(filtered.map(\.languageCode) == ["eng", "deu"])
}

@Test func externalSubtitleFilterKeepsAddOnOrderWithinOneLanguage() {
    let tracks = [track("en", source: "First"), track("eng", source: "Second"), track("ita")]
    let filtered = AppleExternalSubtitleService.filtered(tracks, preferredLanguages: ["eng"])
    #expect(filtered.map(\.id) == ["First:en", "Second:eng"])
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
