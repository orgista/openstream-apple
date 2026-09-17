import Foundation

public extension AppleTitleRating {
    static var selectableCases: [AppleTitleRating] { [.down, .up, .doubleUp] }
    var id: Int { rawValue }
    var title: String {
        switch self { case .down: "Not for Me"; case .none: "Not Rated"; case .up: "I Like This"; case .doubleUp: "Love This" }
    }
    var systemImage: String {
        switch self { case .down: "hand.thumbsdown.fill"; case .none: "hand.thumbsup"; case .up: "hand.thumbsup.fill"; case .doubleUp: "hand.thumbsup.fill" }
    }
}

extension AppleTitleRating: Identifiable {}

public struct AppleTitleRatingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix = "openstream.title-rating.v1."

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func rating(for mediaID: String) -> AppleTitleRating? {
        guard let value = defaults.object(forKey: key(for: mediaID)) as? Int,
              let rating = AppleTitleRating(rawValue: value), rating != .none else { return nil }
        return rating
    }

    public func set(_ rating: AppleTitleRating?, for mediaID: String) {
        let key = key(for: mediaID)
        var ids = Set(defaults.stringArray(forKey: "\(keyPrefix)ids") ?? [])
        let id = ApplePlaybackIdentity.digest(for: mediaID)
        if let rating {
            defaults.set(rating.rawValue, forKey: key)
            ids.insert(id)
        } else {
            defaults.removeObject(forKey: key)
            ids.remove(id)
        }
        defaults.set(Array(ids).sorted(), forKey: "\(keyPrefix)ids")
    }

    public var allRatings: [String: AppleTitleRating] {
        (defaults.stringArray(forKey: "\(keyPrefix)ids") ?? []).reduce(into: [:]) { result, id in
            if let value = defaults.object(forKey: "\(keyPrefix)\(id)") as? Int,
               let rating = AppleTitleRating(rawValue: value), rating != .none {
                result[id] = rating
            }
        }
    }

    private func key(for mediaID: String) -> String {
        keyPrefix + ApplePlaybackIdentity.digest(for: mediaID)
    }
}
