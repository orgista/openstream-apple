import Foundation

public enum AppleIPTVGuideMatching {
    public static func xtreamID(_ channelID: String, manualID: String? = nil, sourceKey: String = "") -> Int? {
        if let manualID, let value = Int(manualID), value > 0 { return value }
        let raw = sourceKey.isEmpty ? channelID : String(channelID.dropFirst(sourceKey.count + 1))
        guard let value = Int(raw), value > 0 else { return nil }
        return value
    }

    public struct Match: Equatable, Sendable {
        public let channelID: String
        public let confidence: Double
    }

    /// Deliberately conservative: an ambiguous normalized name needs a manual assignment.
    public static func match(id: String?, name: String, names: [String: String]) -> Match? {
        Index(names: names).match(id: id, name: name)
    }

    public struct Index: Sendable {
        private let ids: Set<String>
        private let normalized: [String: [String]]
        public init(names: [String: String]) {
            ids = Set(names.keys)
            normalized = Dictionary(grouping: names.keys, by: { normalize(names[$0] ?? "") })
        }
        public func match(id: String?, name: String) -> Match? {
            if let id, ids.contains(id) { return Match(channelID: id, confidence: 1) }
            let key = normalize(name)
            guard !key.isEmpty, let candidates = normalized[key], candidates.count == 1,
                  let candidate = candidates.first else { return nil }
            return Match(channelID: candidate, confidence: 0.95)
        }
    }

    public static func normalize(_ name: String) -> String {
        let decoration: Set<String> = ["hd", "fhd", "uhd", "4k", "8k", "sd", "hevc"]
        let countries: Set<String> = ["us", "usa", "uk", "gb", "ca", "can", "fr", "de", "it", "es", "au"]
        var words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !decoration.contains($0) }
        while let first = words.first, countries.contains(first) { words.removeFirst() }
        return words.joined()
    }
}
