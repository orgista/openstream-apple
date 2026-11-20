import Foundation

/// A storage context, not a profile product. Inject the same namespace into
/// taste stores and keyword caches when the caller already isolates viewers.
public enum AppleTasteNamespace {
    public static let local = "local"

    static func key(_ legacyKey: String, namespace: String) -> String {
        namespace == local ? legacyKey : legacyKey + ".namespace." + ApplePlaybackIdentity.digest(for: namespace)
    }
}
