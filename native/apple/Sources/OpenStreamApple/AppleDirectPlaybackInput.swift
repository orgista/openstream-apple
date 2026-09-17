import Foundation

enum AppleDirectPlaybackInput {
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
