import Foundation

/// A subtitle file beside a library video (a sidecar `.srt`/`.vtt`).
/// `displayName` is what the player's Subtitles section shows, so it already
/// carries the language and the file it came from.
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

    /// Use the same language vocabulary as embedded tracks in the app menu.
    func playbackTrack(id: Int) -> ApplePlaybackTrack {
        let language = AppleSubtitleTrackFilter.normalized(languageCode)
        return ApplePlaybackTrack(
            id: id, title: displayName,
            language: language.isEmpty || language == "und" ? nil : language)
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

/// Loading sidecar subtitle files for the engines.
public enum AppleExternalSubtitleService {
    /// Cap on the size of one subtitle file.
    public static let maximumSubtitleBytes = 4_000_000

    /// Reads one subtitle file (local, network share, or HTTP with the shared
    /// bounded client) when the viewer picks a sidecar track.
    public static let liveDataLoader: @Sendable (URL) async throws -> Data = { url in
        if url.isFileURL {
            return try await AppleLibrarySubtitleService.localData(url)
        }
        if url.scheme?.lowercased() == "smb" {
            let credentials = try await AppleLibrarySubtitleService.credentials(for: url)
            let client = AppleSMBClient()
            do {
                let data = try await client.read(url: url, credentials: credentials,
                    range: 0..<UInt64(maximumSubtitleBytes + 1))
                await client.closeAll()
                guard data.count <= maximumSubtitleBytes else { throw AppleLibrarySourceError.unavailable }
                return data
            } catch {
                await client.closeAll()
                throw error
            }
        }
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
