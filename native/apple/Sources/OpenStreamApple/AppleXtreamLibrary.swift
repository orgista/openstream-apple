import Foundation

public struct AppleXtreamReference: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case movie, series, episode }
    public let sourceID: UUID
    public let kind: Kind
    public let providerID: String
    public var mediaID: String { "xc:\(sourceID.uuidString.lowercased()):\(kind.rawValue):\(providerID)" }

    public static func parse(_ value: String) -> Self? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "xc", let sourceID = UUID(uuidString: String(parts[1])),
              let kind = Kind(rawValue: String(parts[2])), AppleXtreamLibraryPolicy.validID(String(parts[3])) else { return nil }
        return Self(sourceID: sourceID, kind: kind, providerID: String(parts[3]))
    }
}

public enum AppleXtreamLibraryError: Error, Equatable, LocalizedError, Sendable {
    case unavailable, invalidResponse, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Your provider’s movies and series are unavailable."
        case .invalidResponse: "Your provider returned an invalid library."
        case .tooLarge: "Your provider’s category is too large to load."
        }
    }

    /// The Library's line for a provider whose movies and series did not
    /// load, naming it (owner 2026-10-09: "say WHICH provider").
    public static func unavailableMessage(providerName: String) -> String {
        let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return unavailable.localizedDescription }
        let possessive = name.hasSuffix("s") || name.hasSuffix("S") ? "\(name)’" : "\(name)’s"
        return "\(possessive) movies and series are unavailable."
    }
}

public enum AppleXtreamLibraryPolicy {
    public static let maximumBytes = 32 * 1_024 * 1_024
    public static let maximumTitles = 100_000
    public static let pageSize = 100
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    public static func isFresh(storedAt: Date, now: Date) -> Bool {
        (0..<43_200).contains(now.timeIntervalSince(storedAt))
    }
    public static func cacheKey(base: URL, credentials: AppleIPTVCredentials, action: String, argument: String?) -> String {
        ApplePlaybackIdentity.digest(for: "\(base.absoluteString)|\(credentials.username)|\(credentials.password)|\(action)|\(argument ?? "")")
    }
    public static func playbackURL(base: URL, credentials: AppleIPTVCredentials, kind: AppleXtreamReference.Kind,
                                   providerID: String, container: String?) throws -> URL {
        guard kind != .series, validID(providerID) else { throw AppleIPTVError.invalidEndpoint }
        let ext = container.flatMap { $0.isEmpty ? nil : $0 }?.lowercased() ?? "mp4"
        guard ext.count <= 8, ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw AppleIPTVError.invalidEndpoint
        }
        let normalized = try AppleIPTVEndpointPolicy.normalize(base.absoluteString)
        guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else { throw AppleIPTVError.invalidEndpoint }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let username = credentials.username.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let password = credentials.password.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        components.percentEncodedPath = (path.isEmpty ? "" : "/\(path)") + "/\(kind == .movie ? "movie" : "series")/\(username)/\(password)/\(providerID).\(ext)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url, AppleIPTVEndpointPolicy.isPlayable(url) else { throw AppleIPTVError.invalidEndpoint }
        return url
    }
}

public struct AppleXtreamCategory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct AppleXtreamTitle: Codable, Equatable, Identifiable, Sendable {
    public let providerID: String
    public let kind: AppleXtreamReference.Kind
    public let name: String
    public let categoryID: String?
    public let poster: URL?
    public let backdrop: URL?
    public let plot: String?
    public let year: Int?
    public let rating: Double?
    public let container: String?
    public let tmdbID: String?
    public var id: String { "\(kind.rawValue):\(providerID)" }
    public func catalog(sourceID: UUID) -> AppleCatalogItem {
        AppleCatalogItem(mediaID: AppleXtreamReference(sourceID: sourceID, kind: kind, providerID: providerID).mediaID,
            type: kind == .movie ? "movie" : "series", name: name, posterURL: poster, backgroundURL: backdrop,
            summary: plot, releaseInfo: year.map(String.init), rating: rating, year: year)
    }
}

public struct AppleXtreamEpisode: Codable, Equatable, Sendable {
    public let providerID: String
    public let title: String
    public let season: Int
    public let number: Int
    public let container: String?
}

public struct AppleXtreamDetail: Codable, Sendable {
    public let title: AppleXtreamTitle
    public let episodes: [AppleXtreamEpisode]
}
