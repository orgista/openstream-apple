import Foundation

/// A participant-independent identity. Only the channel title and fingerprints
/// cross devices; transport URLs, headers, local source IDs and credentials do not.
struct AppleSharePlayChannel: Codable, Equatable, Sendable {
    enum ValidationError: Error { case invalidIdentity }

    let version: Int
    let title: String
    let channelKey: String
    let guideKey: String?

    init(channel: AppleIPTVChannel) throws {
        let title = Self.cleanTitle(channel.name)
        guard Self.isSafeTitle(title) else { throw ValidationError.invalidIdentity }
        version = 1
        self.title = title
        channelKey = Self.fingerprint(title)
        guideKey = Self.guideFingerprint(channel.guideID)
    }

    var playbackIdentifier: String { "openstream.live.v1.\(channelKey)" }

    /// Resolve exclusively against this participant's available channels. A
    /// same-title tie remains a choice; never silently choose an unrelated feed.
    func candidates(in channels: [AppleIPTVChannel]) -> [AppleIPTVChannel] {
        let sameTitle = channels.filter { Self.fingerprint(Self.cleanTitle($0.name)) == channelKey }
        if let guideKey {
            let exact = sameTitle.filter { Self.guideFingerprint($0.guideID) == guideKey }
            if !exact.isEmpty { return exact }
        }
        return sameTitle
    }

    private enum CodingKeys: String, CodingKey { case version, title, channelKey, guideKey }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        title = try values.decode(String.self, forKey: .title)
        channelKey = try values.decode(String.self, forKey: .channelKey)
        guideKey = try values.decodeIfPresent(String.self, forKey: .guideKey)
        guard version == 1, Self.isSafeTitle(title), Self.cleanTitle(title) == title,
              channelKey == Self.fingerprint(title),
              guideKey.map(Self.isFingerprint) ?? true else {
            throw ValidationError.invalidIdentity
        }
    }

    private static func cleanTitle(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fingerprint(_ value: String) -> String {
        ApplePlaybackIdentity.digest(for: value.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
        ))
    }

    private static func guideFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200,
              clean.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else { return nil }
        return fingerprint(clean)
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }

    private static func isSafeTitle(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let lower = value.lowercased()
        return !lower.contains("://") && !lower.contains("@") && !lower.contains("\\")
            && !["token=", "password=", "username=", "authorization:"].contains(where: lower.contains)
    }
}
