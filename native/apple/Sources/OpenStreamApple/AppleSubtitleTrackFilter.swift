import Foundation

/// Subtitle auto-selection and the captions menu, under one language policy.
///
/// Tagged tracks match the viewer's preferred languages. Untagged tracks are
/// separate manual choices ("CC1", "Subtitles 2") and never qualify for
/// auto-selection.
public enum AppleSubtitleTrackFilter: Sendable {
    /// The languages every captions menu works in, as two-letter codes in
    /// preference order: the given list, or the device's primary language
    /// when the list is empty or names no language.
    public static func effectiveLanguages(
        _ preferredLanguages: [String],
        deviceLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var result: [String] = []
        for code in preferredLanguages.map(normalized) where isLanguage(code) && !result.contains(code) {
            result.append(code)
        }
        guard result.isEmpty else { return result }
        return AppleSubtitleLanguages.deviceDefaults(preferredLanguages: deviceLanguages)
            .map(normalized).filter(isLanguage)
    }

    /// `und`, `zxx`, `mul`, `mis` and an empty tag say nothing about the
    /// language, so they never match a preference. Neither does a word no
    /// language code reduces to: a live playlist's "unknown" or "undefined"
    /// was a language row named after itself (owner 2026-10-22, "(unknown)").
    static func isLanguage(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 3 && !["und", "zxx", "mul", "mis"].contains(code)
    }

    /// The single auto-select candidate: the best track of the first
    /// effective language the stream has, full subtitles ahead of forced,
    /// SDH, commentary and CC. Untagged tracks never qualify.
    /// `isExplicitChoice` no longer changes the result; a guessed language
    /// is as strict as a picked one.
    public static func visible(
        _ tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        isExplicitChoice: Bool = false
    ) -> [ApplePlaybackTrack] {
        let wanted = effectiveLanguages(preferredLanguages)
        // A track only *titled* "Forced" (no forced flag) is a muxer's label,
        // not a forced track: it is never switched on by itself. A flagged
        // one may be, when it is all the language has (V16).
        let eligible = tracks.filter { $0.isForced || !isTitledForced($0) }
        let candidates = wanted.map { language in eligible.filter { languageKey(of: $0) == language } }
        for matches in candidates {
            if let best = matches.min(by: { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                let aIsCC = a.codec?.lowercased() == "cc"
                let bIsCC = b.codec?.lowercased() == "cc"
                if aIsCC != bIsCC { return !aIsCC }
                let aBad = a.isForced || a.title.lowercased().contains("sdh") || a.title.lowercased().contains("commentary")
                let bBad = b.isForced || b.title.lowercased().contains("sdh") || b.title.lowercased().contains("commentary")
                if aBad != bBad { return !aBad }
                return a.id < b.id
            }) {
                return [best]
            }
        }
        return []
    }

    /// One row of a captions menu: a human name and the track it plays.
    public struct MenuChoice: Equatable, Sendable {
        /// The track this row selects: the active one when it belongs to the
        /// row, so the check mark stays on what is drawn; otherwise the best.
        public let track: ApplePlaybackTrack
        /// "English", "English (SDH)", "English (CC)", or an untagged "CC1" / "Subtitles 2".
        public let title: String
        /// Every track the row stands for, the chosen one included.
        public let memberIDs: [Int]
    }

    /// What kind of subtitle a track is, for naming and merging. A row is
    /// one language and one kind.
    enum MenuKind: Int, Comparable {
        case full, sdh, closedCaptions, commentary, forced

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var suffix: String {
            switch self {
            case .full: ""
            case .sdh: "SDH"
            case .closedCaptions: "CC"
            case .commentary: "Commentary"
            case .forced: "Forced"
            }
        }
    }

    /// Every choice once, human-named (owner 2026-09-24: "captions also have
    /// English 1, 2 — it shouldn't have numbers or options").
    ///
    /// Tracks are grouped by language and kind, so three English sidecar files
    /// and the film's own English track are one "English" row.
    /// Within a row the best member plays: text over bitmap, the stream's own
    /// track over a sidecar file, the container default, then the lower id.
    /// A variant gets its own row, named with its kind — "English (SDH)",
    /// "English (Forced)" — only when a plain track of that language exists
    /// too; alone, it simply is "English". Closed captions always say so:
    /// "English (CC)". Effective languages appear first, followed by one
    /// separate choice per untagged track (`untaggedTitles`).
    public static func menuChoices(
        _ tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        activeTrackID: Int? = nil
    ) -> [MenuChoice] {
        let wanted = effectiveLanguages(preferredLanguages)
        let tagged = tracks.filter { wanted.contains(languageKey(of: $0)) }
        let untagged = tracks.filter { languageKey(of: $0).isEmpty }.sorted { $0.id < $1.id }
        let manual = zip(untagged, untaggedTitles(untagged)).map { track, title in
            MenuChoice(track: track, title: title, memberIDs: [track.id])
        }
        return grouped(tagged, wanted: wanted, activeTrackID: activeTrackID) + manual
    }

    /// Names for tracks with no language tag (owner 2026-10-22: Live read
    /// "(unknown)"). A broadcast caption is its service, "CC1"–"CC4", from
    /// the track's own name when it carries one, else the next free number;
    /// anything else is "Subtitles", numbered when there are several. A
    /// muxer's title never names the language (owner 2026-10-14). Two tracks
    /// naming the same service read "CC1" and "CC1 (2)".
    static func untaggedTitles(_ tracks: [ApplePlaybackTrack]) -> [String] {
        var usedServices = Set(tracks.compactMap(captionService))
        let subtitleCount = tracks.filter { kind(of: $0) != .closedCaptions }.count
        var subtitleNumber = 0
        var seen: [String: Int] = [:]
        return tracks.map { track -> String in
            if kind(of: track) == .closedCaptions {
                if let service = captionService(track) { return "CC\(service)" }
                var service = 1
                while usedServices.contains(service) { service += 1 }
                usedServices.insert(service)
                return "CC\(service)"
            }
            subtitleNumber += 1
            return subtitleCount == 1 ? "Subtitles" : "Subtitles \(subtitleNumber)"
        }.map { title in
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            return count == 1 ? title : "\(title) (\(count))"
        }
    }

    /// The CEA-608 service a caption track names itself after ("CC1", "cc3").
    private static func captionService(_ track: ApplePlaybackTrack) -> Int? {
        guard kind(of: track) == .closedCaptions,
              let match = track.title.range(of: #"\bCC[1-4]\b"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return track.title[match].last?.wholeNumberValue
    }

    /// The captions menu's "More…": every tagged language the stream has
    /// that `menuChoices` leaves out, one row per language and kind as
    /// there, alphabetical. English stays the only entry up front; Spanish
    /// and the rest are one step away (full test 2026-10-01).
    public static func otherLanguageChoices(
        _ tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        activeTrackID: Int? = nil
    ) -> [MenuChoice] {
        let wanted = effectiveLanguages(preferredLanguages)
        let others = tracks.filter { track in
            let language = languageKey(of: track)
            return isLanguage(language) && !wanted.contains(language)
        }
        return grouped(others, wanted: [], activeTrackID: activeTrackID)
            .enumerated()
            .sorted { a, b in
                let order = a.element.title.localizedStandardCompare(b.element.title)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }
            .map(\.element)
    }

    private static func grouped(
        _ tracks: [ApplePlaybackTrack],
        wanted: [String],
        activeTrackID: Int?
    ) -> [MenuChoice] {
        struct Key: Hashable { let language: String; let kind: MenuKind }
        var order: [Key] = []
        var members: [Key: [ApplePlaybackTrack]] = [:]
        for track in tracks {
            let key = Key(language: languageKey(of: track), kind: kind(of: track))
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(track)
        }
        // A language with no plain row promotes its best variant to it.
        // Closed captions keep their "(CC)": a broadcast's only English track
        // is still captions, not subtitles.
        let languages = Set(order.map(\.language))
        var promoted: [String: MenuKind] = [:]
        for language in languages where !order.contains(Key(language: language, kind: .full)) {
            promoted[language] = order.filter { $0.language == language && $0.kind != .closedCaptions }.map(\.kind).min()
        }
        // Languages: preferred first, then one holding a default track, then
        // by lowest id — the order the stream lists them in.
        var hasDefault: [String: Bool] = [:]
        var lowestID: [String: Int] = [:]
        for track in tracks {
            let language = languageKey(of: track)
            hasDefault[language] = (hasDefault[language] ?? false) || track.isDefault
            lowestID[language] = min(lowestID[language] ?? .max, track.id)
        }
        let sorted = order.sorted { a, b in
            if a.language != b.language {
                let aRank = wanted.firstIndex(of: a.language) ?? wanted.count
                let bRank = wanted.firstIndex(of: b.language) ?? wanted.count
                if aRank != bRank { return aRank < bRank }
                let aDefault = hasDefault[a.language] ?? false, bDefault = hasDefault[b.language] ?? false
                if aDefault != bDefault { return aDefault }
                return lowestID[a.language, default: 0] < lowestID[b.language, default: 0]
            }
            return a.kind < b.kind
        }
        return sorted.compactMap { key in
            guard let group = members[key], let best = group.min(by: isBetter) else { return nil }
            let chosen = group.first { $0.id == activeTrackID } ?? best
            let name = languageName(key.language)
            let isPlain = key.kind == .full || promoted[key.language] == key.kind
            let title = isPlain || key.kind.suffix.isEmpty ? name : "\(name) (\(key.kind.suffix))"
            return MenuChoice(track: chosen, title: title, memberIDs: group.map(\.id))
        }
    }

    /// The representative tracks of `menuChoices`, in menu order.
    public static func menu(
        _ tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        activeTrackID: Int? = nil
    ) -> [ApplePlaybackTrack] {
        menuChoices(tracks, preferredLanguages: preferredLanguages, activeTrackID: activeTrackID).map(\.track)
    }

    /// Text over bitmap, the stream's own over a sidecar, default, lower id.
    private static func isBetter(_ a: ApplePlaybackTrack, than b: ApplePlaybackTrack) -> Bool {
        let aBitmap = ApplePlayerSubtitleSelection.isBitmap(a), bBitmap = ApplePlayerSubtitleSelection.isBitmap(b)
        if aBitmap != bBitmap { return !aBitmap }
        let aExternal = a.id >= externalTrackIDBase, bExternal = b.id >= externalTrackIDBase
        if aExternal != bExternal { return !aExternal }
        if a.isDefault != b.isDefault { return a.isDefault }
        return a.id < b.id
    }

    /// Both engines number sidecar subtitle files from here.
    static let externalTrackIDBase = 1_000_000

    /// "Forced" in the title with no forced flag set.
    static func isTitledForced(_ track: ApplePlaybackTrack) -> Bool {
        !track.isForced && track.title.range(of: #"\bforced\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func kind(of track: ApplePlaybackTrack) -> MenuKind {
        let title = track.title.lowercased()
        func mentions(_ pattern: String) -> Bool {
            title.range(of: pattern, options: .regularExpression) != nil
        }
        if track.isForced || mentions(#"\bforced\b"#) { return .forced }
        if track.isHearingImpaired || mentions(#"\b(?:sdh|hi|hoh|hearing[ -]impaired|deaf)\b"#) { return .sdh }
        let codec = track.codec?.lowercased() ?? ""
        if ["eia_608", "eia_708", "cea608", "cea708", "cea_708", "cc"].contains(codec)
            || mentions(#"\b(?:cc\d?|closed captions?)\b"#) { return .closedCaptions }
        if mentions(#"\bcommentary\b"#) { return .commentary }
        return .full
    }

    /// Only container language metadata qualifies; a muxer's title is not a tag.
    static func languageKey(of track: ApplePlaybackTrack) -> String {
        let code = normalized(track.language ?? "")
        return isLanguage(code) ? code : ""
    }

    /// "en" → "English". A code the system cannot name stays readable as
    /// the tracks' own word for it rather than a raw code.
    static func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return "Subtitles" }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty,
           name.lowercased() != code {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code.uppercased()
    }

    /// `eng`, `en`, `en-US`, `en_GB`, `fre` (ISO 639-2/B), `fra` (639-2/T)
    /// and `English` or `Français` all reduce to the two-letter code.
    /// `und` and other codes without a language come back unchanged.
    static func normalized(_ value: String) -> String {
        var lower = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        // "English (US)" → "english".
        if let paren = lower.firstIndex(of: "(") {
            lower = lower[..<paren].trimmingCharacters(in: .whitespaces)
        }
        guard !lower.isEmpty else { return "" }
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        if base.count == 2 { return legacyAlpha2[base] ?? base }
        // Matroska writes ISO 639-2/B ("fre", "ger"), which Foundation does
        // not map; without these the menu read "FRE (srt)".
        if let terminology = bibliographicCodes[base] { return terminology }
        if base.count == 3, let alpha2 = Locale.LanguageCode(base).identifier(.alpha2), alpha2.count == 2 {
            return alpha2.lowercased()
        }
        // A spelled-out name, in English, in its own language or in the
        // viewer's ("English", "Español", "Anglais").
        if let named = namedLanguages[fold(lower)] { return named }
        if let alpha2 = Locale.LanguageCode(base).identifier(.alpha2), alpha2.count == 2 {
            return alpha2.lowercased()
        }
        return base
    }

    private static let bibliographicCodes: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl",
        "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi",
        "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
        // OpenSubtitles' own spellings.
        "pob": "pt", "scc": "sr", "scr": "hr",
    ]

    /// Withdrawn two-letter codes some muxers still write.
    private static let legacyAlpha2: [String: String] = ["iw": "he", "in": "id", "ji": "yi"]

    /// Folded language name → two-letter code, for every language the
    /// picker knows: its English name, its own name and the viewer's.
    private static let namedLanguages: [String: String] = {
        var table: [String: String] = [:]
        for (alpha3, english) in AppleSubtitleLanguages.names {
            guard let alpha2 = Locale.LanguageCode(alpha3).identifier(.alpha2) else { continue }
            let code = alpha2.lowercased()
            let names = [english,
                         Locale(identifier: code).localizedString(forLanguageCode: code),
                         Locale.current.localizedString(forLanguageCode: code)]
            for case let name? in names where !name.isEmpty && table[fold(name)] == nil {
                table[fold(name)] = code
            }
        }
        return table
    }()

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func menuLabel(for track: ApplePlaybackTrack) -> String {
        guard !languageKey(of: track).isEmpty else { return "Subtitles" }
        let code = normalized(track.language ?? "")
        if !code.isEmpty, let loc = Locale.current.localizedString(forLanguageCode: code), !loc.isEmpty {
            return loc.capitalized
        }
        var cleanTitle = track.title
        var changed = true
        while changed {
            changed = false
            if let range = cleanTitle.range(of: "\\s+\\d+$", options: .regularExpression) {
                cleanTitle.replaceSubrange(range, with: "")
                changed = true
            }
            if let range = cleanTitle.range(of: "\\s*\\([a-zA-Z\\-]+\\)$", options: .regularExpression) {
                cleanTitle.replaceSubrange(range, with: "")
                changed = true
            }
        }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.isEmpty ? "Subtitles" : cleanTitle
    }
}
