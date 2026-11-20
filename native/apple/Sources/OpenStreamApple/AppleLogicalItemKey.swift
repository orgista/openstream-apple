import Foundation

/// Logical labels for identity classes. Playback continues to use storage keys.
public enum AppleLogicalItemKey {
    public static func title(kind: AppleMediaKind, imdb: String?, tmdb: String?) -> String? {
        if let imdb, !imdb.isEmpty { return "li:\(kind.rawValue):\(imdb.lowercased())" }
        if let tmdb, !tmdb.isEmpty { return "li:\(kind.rawValue):tmdb:\(tmdb.lowercased())" }
        return nil
    }

    public static func episode(seriesKey: String, season: Int, episode: Int) -> String {
        "\(seriesKey):\(season):\(episode)"
    }

    public static func localFileClass(titleKey: String, season: Int?, episode: Int?, sizeBytes: Int64) -> String? {
        guard sizeBytes > 0 else { return nil }
        let key = if let season, let episode { Self.episode(seriesKey: titleKey, season: season, episode: episode) } else { titleKey }
        return "\(key):\(sizeBytes)"
    }

    public static func legacyEpisodeClass(fileEpisodeID: String) -> String { "le:" + fileEpisodeID }
}
