import Foundation

/// Settings › Playback › Audio Language: the language a title starts in when
/// its file carries more than one. Stremio-style containers often flag a dub
/// as the default track ("it plays with a different audio language than what
/// you set", stremio-bugs#917), so the default is the device's language, then
/// English, and the file's own default only when neither is there.
///
/// Stored as one canonical three-letter code (`AppleSubtitleLanguages`
/// vocabulary); no value means "Device Language". Engines read it at load, so
/// every player path honours it without each host passing it in.
public enum AppleAudioLanguagePreference {
    public static let defaultsKey = "openstream.settings.audio.language.v1"

    /// The picker's "Device Language" row.
    public static let automaticTitle = "Device Language"

    /// The stored choice, nil for Device Language.
    public static func storedChoice(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsKey).flatMap(AppleSubtitleLanguages.normalized)
    }

    /// Canonical three-letter codes, best first: the choice alone, or the
    /// device's languages followed by English.
    public static func preferredCodes(
        choice: String?,
        deviceLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        if let choice, let code = AppleSubtitleLanguages.normalized(choice) { return [code] }
        var codes: [String] = []
        for language in deviceLanguages.prefix(4) {
            if let code = AppleSubtitleLanguages.normalized(language), !codes.contains(code) { codes.append(code) }
        }
        if !codes.contains("eng") { codes.append("eng") }
        return codes
    }

    /// For the OpenStream engine's `LoadOptions.preferredAudioLanguages`,
    /// which matches ISO 639-1 and 639-2 (B and T) forms itself.
    public static func engineLanguages(
        choice: String?,
        deviceLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        preferredCodes(choice: choice, deviceLanguages: deviceLanguages)
    }

    /// For `AVPlayerMediaSelectionCriteria`, which wants BCP 47 ("en").
    public static func avPlayerLanguages(
        choice: String?,
        deviceLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        preferredCodes(choice: choice, deviceLanguages: deviceLanguages).map { code in
            AppleSubtitleLanguages.alpha2ToAlpha3.first { $0.value == code && $0.key != "nb" && $0.key != "nn" }?.key
                ?? code
        }
    }
}
