import Foundation

enum AppleDirectPlaybackInput {
    @MainActor
    static func request(for url: URL, store: ApplePlaybackStore = ApplePlaybackStore()) -> ApplePlaybackRequest {
        let mediaID = ApplePlaybackIdentity.digest(for: url.absoluteString)
        return ApplePlaybackRequest(url: url, resumePosition: store.progress(for: mediaID)?.resumePosition,
            mediaID: mediaID, title: url.lastPathComponent, sourceKind: .files)
    }

    static func url(_ input: String) -> URL? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 8192, !clean.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: clean),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
