import Foundation
import Observation

public enum AppleMediaRouteAction: String, Equatable, Sendable {
    case display
    case play
}

public enum AppleAppRoute: Equatable, Sendable {
    case search(String)
    case media(id: String, action: AppleMediaRouteAction)
    case continueWatching

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "openstream", url.user == nil, url.password == nil else { return nil }
        let host = url.host?.lowercased() ?? ""
        let pieces = url.path.split(separator: "/").map(String.init)
        switch host {
        case "search":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "query" })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 200 else { return nil }
            self = .search(value)
        case "media":
            guard let id = pieces.first, id.count == 64,
                  id.allSatisfy({ $0.isHexDigit }),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let actionValue = components.queryItems?.first(where: { $0.name == "action" })?.value ?? "display"
            guard let action = AppleMediaRouteAction(rawValue: actionValue) else { return nil }
            self = .media(id: id.lowercased(), action: action)
        case "continue":
            guard pieces.isEmpty else { return nil }
            self = .continueWatching
        default:
            return nil
        }
    }
}

@MainActor
@Observable
public final class AppleAppRouter {
    public private(set) var route: AppleAppRoute?
    public private(set) var searchQuery = ""
    public private(set) var revision = 0

    public init() {}

    public func open(_ url: URL) {
        guard let value = AppleAppRoute(url: url) else { return }
        route = value
        if case .search(let query) = value { searchQuery = query }
        revision &+= 1
    }

    public func showSearch(_ query: String) {
        let clean = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty else { return }
        searchQuery = clean
        route = .search(clean)
        revision &+= 1
    }
}
