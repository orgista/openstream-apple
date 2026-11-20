import Foundation

enum AppleCatalogShelfPolicy {
    /// Strong IDs and known title/year identities merge across sources, as
    /// recommendation diversity does.
    static func identity(_ item: AppleCatalogItem, source: AppleSource? = nil) -> String {
        AppleRecommendationInputs.identity(item, sourceID: "")
    }

    /// Incremental soft overlap cost for recommendation composition only.
    /// Continue Watching never calls this.
    struct DiversitySignals: Sendable {
        let primaryGenre: String?
        let franchise: String?
        let source: String?

        init(primaryGenre: String? = nil, franchise: String? = nil, source: String? = nil) {
            func clean(_ value: String?) -> String? {
                guard let value else { return nil }
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
            self.primaryGenre = clean(primaryGenre)
            self.franchise = clean(franchise)
            self.source = clean(source)
        }
    }

    static func diversityPenalty(_ signals: DiversitySignals, selected: [DiversitySignals], unit: Double) -> Double {
        selected.reduce(0) { total, prior in
            total + (signals.primaryGenre != nil && signals.primaryGenre == prior.primaryGenre ? unit : 0)
                + (signals.franchise != nil && signals.franchise == prior.franchise ? unit : 0)
                + (signals.source != nil && signals.source == prior.source ? unit * 0.25 : 0)
        }
    }

    /// Conservative sequel families only; a common first word is not a franchise.
    static func franchise(title: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colon = name.firstIndex(of: ":"), name[..<colon].split(separator: " ").count >= 2 {
            return String(name[..<colon])
        }
        var words = name.split(separator: " ")
        guard let last = words.last, Int(last) != nil || ["ii", "iii", "iv", "v", "vi"].contains(last),
              words.count >= 3 else { return nil }
        words.removeLast()
        return words.joined(separator: " ")
    }

    static func hasDiscoverContent(hasLocalLibrary: Bool, hasMediaServerItems: Bool, hasTop10: Bool = false) -> Bool {
        hasLocalLibrary || hasMediaServerItems || hasTop10
    }

    static func rankedSubtitle(for item: AppleCatalogItem) -> String {
        [item.year.map { String($0) } ?? item.releaseInfo.map(AppleReleaseYearText.display), item.genres?.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A source's name as a search row shows it: whitespace collapsed and a
    /// trailing " | Host" dropped.
    static func displaySourceName(_ name: String) -> String {
        let collapse: (Substring) -> String = {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let full = collapse(Substring(name))
        guard let bar = name.firstIndex(of: "|") else { return full }
        let head = collapse(name[..<bar])
        return head.isEmpty ? full : head
    }

    /// First occurrence wins. A shelf keys its `ForEach` on `id`, so a repeated
    /// id draws one card twice under one accessibility identifier — which
    /// SwiftUI treats as undefined and XCTest cannot resolve.
    static func uniqueByID<Value: Identifiable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }
}
