import Foundation

/// The language vocabulary the captions menu works in. Add-ons report `lang`
/// in whatever shape they like ("en", "eng", "pt-BR", "English"), so every
/// value is folded to the three-letter code OpenSubtitles uses before it is
/// compared with the viewer's preferred languages.
public enum AppleSubtitleLanguages {
    /// How many languages the viewer may keep in the preference list.
    public static let maximumSelection = 3

    public struct Language: Identifiable, Hashable, Sendable {
        public let code: String
        public let name: String

        public var id: String { code }
    }

    /// The persisted preference list, also read by the playback coordinator
    /// when no host handed it one.
    public static let defaultsKey = "openstream.settings.subtitle.languages.v1"

    /// Three-letter code → English name. Doubles as the canonical list of
    /// languages the picker offers and as the fallback when the system has no
    /// localized name for a code.
    static let names: [String: String] = [
        "ara": "Arabic",
        "ben": "Bengali",
        "bul": "Bulgarian",
        "cat": "Catalan",
        "ces": "Czech",
        "dan": "Danish",
        "deu": "German",
        "ell": "Greek",
        "eng": "English",
        "est": "Estonian",
        "fas": "Persian",
        "fin": "Finnish",
        "fra": "French",
        "heb": "Hebrew",
        "hin": "Hindi",
        "hrv": "Croatian",
        "hun": "Hungarian",
        "ind": "Indonesian",
        "isl": "Icelandic",
        "ita": "Italian",
        "jpn": "Japanese",
        "kor": "Korean",
        "lav": "Latvian",
        "lit": "Lithuanian",
        "msa": "Malay",
        "nld": "Dutch",
        "nor": "Norwegian",
        "pol": "Polish",
        "por": "Portuguese",
        "ron": "Romanian",
        "rus": "Russian",
        "slk": "Slovak",
        "slv": "Slovenian",
        "spa": "Spanish",
        "srp": "Serbian",
        "swe": "Swedish",
        "tam": "Tamil",
        "tel": "Telugu",
        "tha": "Thai",
        "tur": "Turkish",
        "ukr": "Ukrainian",
        "vie": "Vietnamese",
        "zho": "Chinese",
    ]

    /// Two-letter to three-letter, for the codes above plus the alternates
    /// add-ons still send ("chi", "fre", "ger", "dut", "gre", "per", "rum").
    static let alpha2ToAlpha3: [String: String] = [
        "ar": "ara", "bn": "ben", "bg": "bul", "ca": "cat", "cs": "ces",
        "da": "dan", "de": "deu", "el": "ell", "en": "eng", "et": "est",
        "fa": "fas", "fi": "fin", "fr": "fra", "he": "heb", "hi": "hin",
        "hr": "hrv", "hu": "hun", "id": "ind", "is": "isl", "it": "ita",
        "ja": "jpn", "ko": "kor", "lv": "lav", "lt": "lit", "ms": "msa",
        "nl": "nld", "no": "nor", "nb": "nor", "nn": "nor", "pl": "pol",
        "pt": "por", "ro": "ron", "ru": "rus", "sk": "slk", "sl": "slv",
        "es": "spa", "sr": "srp", "sv": "swe", "ta": "tam", "te": "tel",
        "th": "tha", "tr": "tur", "uk": "ukr", "vi": "vie", "zh": "zho",
    ]

    /// Alternate three-letter forms (ISO 639-2/B and OpenSubtitles spellings)
    /// folded onto the canonical code.
    static let alpha3Aliases: [String: String] = [
        "chi": "zho", "cze": "ces", "dut": "nld", "fre": "fra", "ger": "deu", "gre": "ell", "ice": "isl", "may": "msa", "per": "fas",
        "rum": "ron", "slo": "slk", "scc": "srp", "scr": "hrv", "pob": "por",
        "pt-br": "por", "nob": "nor", "nno": "nor",
    ]

    /// Every language the picker offers, ordered by display name in the
    /// viewer's locale.
    public static var all: [Language] {
        names.keys
            .map { Language(code: $0, name: displayName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The localized name for a canonical code, falling back to the built-in
    /// English table and finally to the uppercased code.
    public static func displayName(for code: String) -> String {
        let canonical = normalized(code) ?? code.lowercased()
        if let name = Locale.current.localizedString(forLanguageCode: canonical),
           !name.isEmpty, name.lowercased() != canonical {
            return name
        }
        if let name = names[canonical] { return name }
        return canonical.uppercased()
    }

    /// Folds an add-on `lang` value, a BCP 47 tag or a language name onto a
    /// canonical three-letter code. Returns `nil` when nothing matches.
    public static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }

        if let alias = alpha3Aliases[trimmed] { return alias }
        if names[trimmed] != nil { return trimmed }

        let base = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        if let alias = alpha3Aliases[base] { return alias }
        if names[base] != nil { return base }
        if let mapped = alpha2ToAlpha3[base] { return mapped }

        // "English", "Português" and the like, via the built-in table first so
        // the answer does not depend on the device locale.
        if let match = names.first(where: { $0.value.lowercased() == trimmed })?.key { return match }
        if let match = names.keys.first(where: { displayName(for: $0).lowercased() == trimmed }) { return match }

        return nil
    }

    /// The resource name an add-on manifest declares when it serves subtitles.
    static let subtitlesResource = "subtitles"

    /// Whether a manifest's resource list declares subtitles, which is the
    /// only case where a source is offered the subtitle language picker.
    public static func declaresSubtitles(resources: [String]) -> Bool {
        resources.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(subtitlesResource) == .orderedSame }
    }

    /// English plus the device's preferred languages as canonical codes,
    /// English first, capped at `maximumSelection` and de-duplicated. Most
    /// add-on subtitles are English, so it is always worth listing.
    public static func deviceDefaults(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var codes: [String] = ["eng"]
        for language in preferredLanguages {
            guard let code = normalized(language), !codes.contains(code) else { continue }
            codes.append(code)
            if codes.count >= maximumSelection { break }
        }
        return codes
    }

    /// Toggles one code in the preference list, refusing to grow it beyond
    /// `maximumSelection`.
    public static func toggling(_ code: String, in current: [String]) -> [String] {
        guard let canonical = normalized(code) else { return current }
        if let index = current.firstIndex(of: canonical) {
            var next = current
            next.remove(at: index)
            return next
        }
        guard current.count < maximumSelection else { return current }
        return current + [canonical]
    }

    /// Drops unknown codes, duplicates and anything past `maximumSelection`.
    public static func sanitized(_ codes: [String]) -> [String] {
        var result: [String] = []
        for code in codes {
            guard let canonical = normalized(code), !result.contains(canonical) else { continue }
            result.append(canonical)
            if result.count >= maximumSelection { break }
        }
        return result
    }

    /// The stored preference list, or the device defaults when the viewer has
    /// not chosen yet.
    public static func storedPreferredLanguages(
        defaults: UserDefaults = .standard
    ) -> [String] {
        guard let stored = defaults.stringArray(forKey: defaultsKey) else { return deviceDefaults() }
        return sanitized(stored)
    }
}
