import Foundation

enum AppleHomeRowLabel {
    static func baseName(_ name: String) -> String {
        let split = name.replacingOccurrences(of: #"\([^)]*\)"#, with: " · ", options: .regularExpression)
            .replacingOccurrences(of: " - ", with: " · ")
            .replacingOccurrences(of: " | ", with: " · ")
        return split.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    static func clean(name: String, mediaTypes: Set<String>) -> String {
        let name = baseName(name)
        guard !name.isEmpty else { return "" }
        let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if mediaTypes == ["movie"], words.isDisjoint(with: ["movie", "movies", "film"]) { return name + " Movies" }
        if mediaTypes == ["series"], words.isDisjoint(with: ["show", "shows", "series", "tv"]) { return name + " Shows" }
        return name
    }
}
