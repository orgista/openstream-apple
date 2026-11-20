import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Preferred audio language")
struct AppleAudioLanguagePreferenceTests {
    @Test("Device Language: the device's languages, then English")
    func automaticFollowsTheDevice() {
        #expect(AppleAudioLanguagePreference.preferredCodes(choice: nil, deviceLanguages: ["en-US"]) == ["eng"])
        #expect(AppleAudioLanguagePreference.preferredCodes(choice: nil, deviceLanguages: ["fr-CA", "de-DE"])
                == ["fra", "deu", "eng"])
        #expect(AppleAudioLanguagePreference.preferredCodes(choice: nil, deviceLanguages: []) == ["eng"])
        // Unknown device languages fall through to English.
        #expect(AppleAudioLanguagePreference.preferredCodes(choice: nil, deviceLanguages: ["xx-YY"]) == ["eng"])
    }

    @Test("A chosen language is the whole preference; ISO 639-1 and 639-2 forms fold together", arguments: [
        "en", "eng", "EN", "English",
    ])
    func choiceNormalises(_ choice: String) {
        #expect(AppleAudioLanguagePreference.preferredCodes(choice: choice, deviceLanguages: ["ru-RU"]) == ["eng"])
    }

    @Test("AVPlayer gets BCP 47 codes")
    func avPlayerCodes() {
        #expect(AppleAudioLanguagePreference.avPlayerLanguages(choice: "spa") == ["es"])
        #expect(AppleAudioLanguagePreference.avPlayerLanguages(choice: nil, deviceLanguages: ["fr-FR"]) == ["fr", "en"])
        #expect(AppleAudioLanguagePreference.avPlayerLanguages(choice: "nor") == ["no"])
    }

    @Test("The engine load options carry the preference, independent of captions")
    func loadOptionsCarryIt() throws {
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/MultiAudio.mkv")),
                                           mediaID: "multi", sourceKind: .files)
        let options = AetherPlaybackEngine.loadOptions(
            for: request, headers: [:], captionsPreference: .off, preferredAudioLanguages: ["eng"])
        #expect(options.preferredAudioLanguages == ["eng"])
        #expect(options.preferredSubtitleLanguages.isEmpty)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).preferredAudioLanguages.isEmpty)
    }

    @MainActor @Test("Settings stores the choice, clears it for Device Language, and backs it up")
    func settingsPersist() throws {
        let name = "audio-language-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: AudioLanguageTestCredentials())
        #expect(settings.audioLanguage == "")
        #expect(AppleAudioLanguagePreference.storedChoice(defaults: defaults) == nil)
        settings.audioLanguage = "jpn"
        #expect(AppleAudioLanguagePreference.storedChoice(defaults: defaults) == "jpn")
        #expect(AppleSettingsStore(defaults: defaults, keychain: AudioLanguageTestCredentials()).audioLanguage == "jpn")
        settings.audioLanguage = ""
        #expect(defaults.object(forKey: AppleAudioLanguagePreference.defaultsKey) == nil)
        #expect(AppleSettingsStore.configurationKeys.contains(AppleAudioLanguagePreference.defaultsKey))
    }
}

private final class AudioLanguageTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}
