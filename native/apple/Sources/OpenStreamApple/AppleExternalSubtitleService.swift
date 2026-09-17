import Foundation

/// A subtitle file offered by an installed add-on for the title being played.
/// `displayName` is what the player's Subtitles section shows, so it already
/// carries the language and the add-on it came from.
public struct AppleExternalSubtitleTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let languageCode: String
    public let displayName: String
    public let url: URL

    public init(id: String, languageCode: String, displayName: String, url: URL) {
        self.id = id
        self.languageCode = languageCode
        self.displayName = displayName
        self.url = url
    }

    public init(id: String, languageCode: String, sourceName: String?, url: URL) {
        self.init(
            id: id,
            languageCode: Self.normalizedLanguageCode(languageCode),
            displayName: Self.displayName(
                languageCode: Self.normalizedLanguageCode(languageCode),
                sourceName: sourceName
            ),
            url: url
        )
    }

    static func normalizedLanguageCode(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(20))
    }

    static func displayName(languageCode: String, sourceName: String?) -> String {
        let language = languageName(for: languageCode)
        let source = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source.isEmpty ? language : "\(language) (\(source))"
    }

    /// "eng" / "en" → "English". Unknown codes are shown uppercased so the row
    /// still names something the viewer can pick between.
    static func languageName(for code: String) -> String {
        guard !code.isEmpty else { return "Subtitles" }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty, name != code {
            return name
        }
        return code.uppercased()
    }
}

/// The media identity an add-on needs for a `subtitles` request: the type
/// (`movie` / `series`) and the add-on media id, with the season and episode
/// already folded into the id for a series.
public struct AppleExternalSubtitleQuery: Hashable, Sendable {
    public let type: String
    public let mediaID: String

    public init?(type: String, mediaID: String, season: Int? = nil, episode: Int? = nil) {
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanType.isEmpty, !cleanID.isEmpty, cleanID.count <= 300 else { return nil }
        if let season, let episode, !cleanID.contains(":") {
            cleanID += ":\(season):\(episode)"
        }
        self.type = cleanType
        self.mediaID = cleanID
    }

    public init?(request: ApplePlaybackRequest) {
        guard let mediaID = request.hints.addonMediaID else { return nil }
        self.init(type: request.hints.addonMediaType ?? "movie", mediaID: mediaID)
    }

    var cacheKey: String { "\(type):\(mediaID)" }
}

/// Queries every enabled add-on that declares the `subtitles` resource for one
/// title and merges the answers into one per-language list. Each add-on gets
/// its own bounded window and fails open: a slow or broken add-on never blocks
/// the others and never surfaces an error, because subtitles are additive to a
/// stream that is already playing. Results are cached per media id for the
/// lifetime of the process.
public actor AppleExternalSubtitleService {
    public static let shared = AppleExternalSubtitleService()

    /// Cap on merged tracks for one title, and on the size of one downloaded
    /// subtitle file.
    public static let maximumTracks = 60
    public static let maximumSubtitleBytes = 4_000_000

    private let client: AppleStremioPlaybackClient
    private let timeout: Duration
    private var cache: [String: [AppleExternalSubtitleTrack]] = [:]

    public init(
        client: AppleStremioPlaybackClient = AppleStremioPlaybackClient(),
        timeout: Duration = .seconds(6)
    ) {
        self.client = client
        self.timeout = timeout
    }

    public func tracks(
        for query: AppleExternalSubtitleQuery,
        sources: [AppleSource],
        preferredLanguages: [String] = []
    ) async -> [AppleExternalSubtitleTrack] {
        if let cached = cache[query.cacheKey] {
            return Self.filtered(cached, preferredLanguages: preferredLanguages)
        }
        let candidates = sources.filter { source in
            source.kind == .stremio && source.isEnabled
                && source.resources.contains { $0.caseInsensitiveCompare("subtitles") == .orderedSame }
        }
        guard !candidates.isEmpty else { return [] }

        let client = self.client
        let timeout = self.timeout
        let answers = await withTaskGroup(
            of: (Int, String, [AppleStremioSubtitleTrack]).self,
            returning: [Int: (String, [AppleStremioSubtitleTrack])].self
        ) { group in
            for (index, source) in candidates.enumerated() {
                group.addTask {
                    let tracks = await Self.fetch(client: client, source: source, query: query, timeout: timeout)
                    return (index, source.name, tracks)
                }
            }
            var collected: [Int: (String, [AppleStremioSubtitleTrack])] = [:]
            for await (index, name, tracks) in group { collected[index] = (name, tracks) }
            return collected
        }

        var merged: [AppleExternalSubtitleTrack] = []
        var seenLanguages = Set<String>()
        for index in candidates.indices {
            guard let (sourceName, tracks) = answers[index] else { continue }
            for track in tracks {
                let language = AppleExternalSubtitleTrack.normalizedLanguageCode(track.language)
                guard !language.isEmpty, seenLanguages.insert(language).inserted else { continue }
                merged.append(
                    AppleExternalSubtitleTrack(
                        id: "\(candidates[index].id.uuidString):\(track.id)",
                        languageCode: language,
                        sourceName: sourceName,
                        url: track.url
                    )
                )
                if merged.count >= Self.maximumTracks { break }
            }
            if merged.count >= Self.maximumTracks { break }
        }
        cache[query.cacheKey] = merged
        return Self.filtered(merged, preferredLanguages: preferredLanguages)
    }

    /// Keeps only the tracks whose language is in `preferredLanguages`, in
    /// preference order first and add-on order within a language. An empty
    /// preference list keeps everything, so a viewer who has cleared the list
    /// still sees whatever the add-ons offer.
    static func filtered(
        _ tracks: [AppleExternalSubtitleTrack],
        preferredLanguages: [String]
    ) -> [AppleExternalSubtitleTrack] {
        let preferred = AppleSubtitleLanguages.sanitized(preferredLanguages)
        guard !preferred.isEmpty else { return tracks }
        var result: [AppleExternalSubtitleTrack] = []
        for code in preferred {
            for track in tracks where AppleSubtitleLanguages.normalized(track.languageCode) == code {
                result.append(track)
            }
        }
        return result
    }

    private static func fetch(
        client: AppleStremioPlaybackClient,
        source: AppleSource,
        query: AppleExternalSubtitleQuery,
        timeout: Duration
    ) async -> [AppleStremioSubtitleTrack] {
        await withTaskGroup(of: [AppleStremioSubtitleTrack]?.self) { group in
            group.addTask {
                try? await client.subtitles(source: source, type: query.type, mediaID: query.mediaID)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// Downloads one subtitle file with the shared bounded HTTP client. Used by
    /// the engine when the viewer picks an add-on subtitle track.
    public static let liveDataLoader: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await AppleBoundedHTTPDataLoader.load(
            request,
            maximumBytes: maximumSubtitleBytes,
            redirectPolicy: .secureHTTPOnly
        )
        return data
    }
}
