#if OPENSTREAM_ADDONS
import Foundation

/// Whether a Stremio add-on's manifest URL carries the viewer's own sign-in.
///
/// An unconfigured add-on (`https://v3-cinemeta.strem.io/manifest.json`) has
/// the same address for everyone, so the iCloud snapshot can carry it in full
/// and it restores enabled. A configured add-on puts its options, and often a
/// debrid or API key, in a path segment before `manifest.json`
/// (`/realdebrid=…|sort=…/manifest.json`, a base64 or JSON blob); that address
/// is a secret and only ever travels sealed.
public enum AppleAddonURLSecretPolicy {
    /// True unless the URL is a plain http(s) manifest address with no
    /// userinfo, query, fragment or configuration segment.
    public static func isSecret(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return true }
        if parts.user != nil || parts.password != nil { return true }
        if let query = parts.percentEncodedQuery, !query.isEmpty { return true }
        if let fragment = parts.percentEncodedFragment, !fragment.isEmpty { return true }
        let segments = parts.percentEncodedPath.split(separator: "/").map(String.init)
        guard segments.last?.lowercased() == "manifest.json" else { return true }
        return segments.dropLast().contains(where: isConfigurationSegment)
    }

    /// For an add-on's other addresses (its logo): secret when it has
    /// userinfo, a query, or a configuration segment anywhere before its file name.
    public static func isSecretAsset(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return true }
        if parts.user != nil || parts.password != nil { return true }
        if let query = parts.percentEncodedQuery, !query.isEmpty { return true }
        return parts.percentEncodedPath.split(separator: "/").map(String.init).dropLast()
            .contains(where: isConfigurationSegment)
    }

    /// A path segment that holds add-on options rather than a plain folder
    /// name: JSON-ish or key=value, naming a debrid service or key, or long
    /// and not made of plain words (base64, hex or random keys). A long name
    /// of words such as `org.stremio.NoReservationDailyMotion` or
    /// `stremio-xmas-marathon` is a folder (add-on sweep 2026-09-30: 14
    /// public add-ons were sealed for their repository names).
    static func isConfigurationSegment(_ segment: String) -> Bool {
        let decoded = segment.removingPercentEncoding ?? segment
        // Options as JSON, plain or base64: secret only when a value is.
        // `{}`, `{"tmdbKey":""}` and `{"torbox":"unset","sort":"desc"}` hold
        // no key (add-on sweep 2026-10-01: 4 public add-ons were sealed).
        if let options = jsonOptions(decoded) { return containsSecret(options, key: "") }
        let markers = CharacterSet(charactersIn: "=|{}[]:;,&%\"'+~!@$*()")
        if segment.rangeOfCharacter(from: markers) != nil || decoded.rangeOfCharacter(from: markers) != nil {
            return true
        }
        let lowered = decoded.lowercased()
        if keyNames.contains(where: { lowered.contains($0) }) { return true }
        return decoded.count >= 16 && !isPlainWords(decoded)
    }

    /// Words joined by `-`, `_` or `.`: ASCII letters with few digits, no
    /// word longer than 24 characters, capitals only at word starts (at most
    /// a quarter of a word), and a vowel in every longer word.
    static func isPlainWords(_ value: String) -> Bool {
        guard value.count <= 64, value.allSatisfy({ $0.isASCII }) else { return false }
        guard value.filter(\.isNumber).count <= 4 else { return false }
        let words = value.split(whereSeparator: { "-_.".contains($0) })
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            guard word.count <= 24, word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            let capitals = word.filter(\.isUppercase).count
            guard capitals <= max(2, word.count / 4) else { return false }
            let letters = word.filter(\.isLetter)
            return letters.count < 6 || letters.lowercased().contains(where: { "aeiouy".contains($0) })
        }
    }

    /// The segment's options when it is a JSON object, as text or as
    /// base64 (standard or URL-safe) of one.
    static func jsonOptions(_ value: String) -> [String: Any]? {
        guard value.utf8.count <= 8_192 else { return nil }
        if value.hasPrefix("{") {
            return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
        }
        guard value.utf8.count >= 4,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_+/=".contains($0)) }) else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.first == UInt8(ascii: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whether a JSON option holds a secret: a non-empty value under a key
    /// or service name, a value shaped like a key (long base64 or hex, a
    /// UUID), or an address with sign-in, a query or a configuration path.
    private static func containsSecret(_ value: Any, key: String) -> Bool {
        switch value {
        case let object as [String: Any]:
            return object.contains { containsSecret($0.value, key: $0.key) }
        case let list as [Any]:
            return list.contains { containsSecret($0, key: key) }
        case let text as String:
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || placeholders.contains(clean.lowercased()) { return false }
            let name = key.lowercased()
            if (keyNames + optionKeyNames).contains(where: { name.contains($0) }) { return true }
            // Any address in the options is treated as private: playlist and
            // panel addresses often carry the sign-in in their path
            // (http://host/user/pass/playlist.m3u).
            if let url = URL(string: clean), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return true
            }
            return clean.count >= 16
                && clean.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_+/=.".contains($0)) })
                && !isPlainWords(clean)
        default:
            return false
        }
    }

    /// Values that mean "not set" in add-on options.
    private static let placeholders: Set<String> = ["unset", "none", "null", "false", "true", "no", "off", "disabled"]

    /// Option names that hold a key or a sign-in.
    private static let optionKeyNames = ["key", "user", "pass", "pw", "pin", "cred", "login", "email", "cookie", "session", "uuid"]

    private static let keyNames = [
        "debrid", "premiumize", "torbox", "offcloud", "putio", "easynews",
        "apikey", "api_key", "api-key", "token", "password", "secret", "auth",
    ]
}

#endif
