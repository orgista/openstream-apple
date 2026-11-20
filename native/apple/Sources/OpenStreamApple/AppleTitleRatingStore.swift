import Foundation
import Synchronization

public extension AppleTitleRating {
    static var selectableCases: [AppleTitleRating] { [.down, .up, .doubleUp] }
    var id: Int { rawValue }
    var title: String {
        switch self { case .down: "Not for Me"; case .none: "Not Rated"; case .up: "I Like This"; case .doubleUp: "Love This" }
    }
    var systemImage: String {
        AppleSemanticAction.rating(self, selected: self != .none).symbol
    }
}

extension AppleTitleRating: Identifiable {}

public struct AppleTitleRatingStore: @unchecked Sendable {
    static let changeNotification = Notification.Name("OpenStreamTitleRatingsChanged")
    private static let revisionCounter = Mutex<UInt64>(0)
    /// Process-local invalidation; persisted ratings remain the source of truth.
    static var revision: UInt64 { revisionCounter.withLock { $0 } }

    private static func didChange() {
        revisionCounter.withLock { $0 &+= 1 }
        NotificationCenter.default.post(name: changeNotification, object: nil)
    }

    private let defaults: UserDefaults
    private let keyPrefix: String
    public let namespace: String

    public init(defaults: UserDefaults = .standard, namespace: String = AppleTasteNamespace.local) {
        self.defaults = defaults
        self.namespace = namespace
        keyPrefix = AppleTasteNamespace.key("openstream.title-rating.v1", namespace: namespace) + "."
    }

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
        Self.didChange()
    }

    public var allRatings: [String: AppleTitleRating] {
        (defaults.stringArray(forKey: "\(keyPrefix)ids") ?? []).reduce(into: [:]) { result, id in
            if let value = defaults.object(forKey: "\(keyPrefix)\(id)") as? Int,
               let rating = AppleTitleRating(rawValue: value), rating != .none {
                result[id] = rating
            }
        }
    }

    func restoreConfigurationRatings(_ values: [String: Int]) {
        for id in defaults.stringArray(forKey: "\(keyPrefix)ids") ?? [] {
            defaults.removeObject(forKey: keyPrefix + id)
        }
        let valid = values.filter { AppleTitleRating(rawValue: $0.value) != nil }
        for (id, rating) in valid { defaults.set(rating, forKey: keyPrefix + id) }
        defaults.set(valid.keys.sorted(), forKey: "\(keyPrefix)ids")
        Self.didChange()
    }

    private func key(for mediaID: String) -> String {
        keyPrefix + ApplePlaybackIdentity.digest(for: mediaID)
    }
}
