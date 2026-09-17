import Foundation

/// Extracts a validated HTTPS icon or logo URL from an add-on manifest.
public struct AppleAddonManifestIcon: Sendable, Equatable {
    public let url: URL
    
    /// Parses the manifest JSON data and returns the extracted valid icon/logo URL if present.
    /// Prefers `icon` over `logo` if both are present.
    /// Validates that the URL is HTTPS, credential-free, and bounded (≤ 1024 characters).
    public static func extract(fromManifestData data: Data) -> AppleAddonManifestIcon? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return extract(fromManifestDictionary: json)
    }
    
    /// Parses the manifest dictionary and returns the extracted valid icon/logo URL if present.
    public static func extract(fromManifestDictionary dictionary: [String: Any]) -> AppleAddonManifestIcon? {
        let maxURLLength = 1024
        
        let iconString = dictionary["icon"] as? String
        let logoString = dictionary["logo"] as? String
        
        for candidate in [iconString, logoString] {
            guard let candidateString = candidate,
                  candidateString.count <= maxURLLength,
                  let url = URL(string: candidateString),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else {
                continue
            }
            return AppleAddonManifestIcon(url: url)
        }
        
        return nil
    }
}
