import Foundation
import Observation

public enum AppleMediaRouteAction: String, Equatable, Sendable {
    case display
    case play
}

public enum AppleAppRoute: Equatable, Sendable {
    case search(String)
    case media(id: String, action: AppleMediaRouteAction)
    case sharedLink(SharedLink)
    case continueWatching
    case live(channelID: String)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "openstream", url.user == nil, url.password == nil else { return nil }
        let host = url.host?.lowercased() ?? ""
        let pieces = url.path.split(separator: "/").map(String.init)
        switch host {
        case "open":
            guard pieces.isEmpty,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let sharedURL = URL(string: raw),
                  let link = AppleSharedLinkResolver.parse(sharedURL) else { return nil }
            self = .sharedLink(link)
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
        case "live":
            guard pieces.count == 1, let id = pieces.first, Self.liveURL(channelID: id) != nil else { return nil }
            self = .live(channelID: id)
        case "continue":
            guard pieces.isEmpty else { return nil }
            self = .continueWatching
        default:
            return nil
        }
    }
}

public extension AppleAppRoute {
    static func liveURL(channelID: String) -> URL? {
        guard !channelID.isEmpty, channelID.count <= 512,
              channelID.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-").contains($0)
              }) else { return nil }
        var components = URLComponents()
        components.scheme = "openstream"
        components.host = "live"
        components.path = "/" + channelID
        return components.url
    }

    /// A tapped Spotlight result: the item's unique identifier is the media
    /// record id (`AppleSpotlightIndexer`), so it opens that title's page.
    init?(spotlightIdentifier: String) {
        let id = spotlightIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 64, id.allSatisfy(\.isHexDigit) else { return nil }
        self = .media(id: id, action: .display)
    }
}

@MainActor
@Observable
public final class AppleAppRouter {
    public private(set) var route: AppleAppRoute?
    public private(set) var searchQuery = ""
    public private(set) var revision = 0
    public private(set) var pendingExternalLiveChannelID: String?
    /// A scanned Set Up from iPhone code (`openstream://send-setup?…`): the
    /// root asks "Send your setup to …?" (`AppleSetupTransferHost`).
    public private(set) var setupSendLink: AppleSetupTransferLink?

    public init() {}

    public func open(_ url: URL) {
        if url.scheme?.lowercased() == "openstream", url.host?.lowercased() == "send-setup" {
            guard let link = AppleSetupTransferLink(url: url) else {
                appleTraceFailure("setup send link refused")
                return
            }
            appleTrace("setup send link opened")
            setupSendLink = link
            return
        }
        guard let value = AppleAppRoute(url: url) else { return }
        if case .sharedLink = value { AppleSharedLinkHandoff.clear(matching: url) }
        // A URL can come from any app or web page. Show the title so the
        // viewer chooses Play; typed routes from Siri/Shortcuts retain intent.
        if case .media(let id, .play) = value { open(.media(id: id, action: .display)) }
        else {
            open(value)
            if case .live(let id) = value { pendingExternalLiveChannelID = id }
        }
    }

    public func clearExternalLivePlayback() {
        guard pendingExternalLiveChannelID != nil else { return }
        pendingExternalLiveChannelID = nil
        route = nil
        revision &+= 1
    }

    public func confirmExternalLivePlayback() {
        guard let id = pendingExternalLiveChannelID else { return }
        open(.live(channelID: id))
    }

    public func clearSetupSendLink() { setupSendLink = nil }

    public func consumePendingSharedLink() {
        guard let url = AppleSharedLinkHandoff.take() else { return }
        appleTrace("shared link pending handoff")
        open(url)
    }

    /// A route that did not come from a URL: an App Intent (Siri, Shortcuts,
    /// Spotlight) handed over through `AppleAppIntentHandoff`.
    public func open(_ value: AppleAppRoute) {
        pendingExternalLiveChannelID = nil
        route = value
        if case .search(let query) = value { searchQuery = query }
        if case .sharedLink = value { searchQuery = "" }
        revision &+= 1
    }

    /// Continues a tapped Spotlight result (`CSSearchableItemActionType`):
    /// `identifier` is `CSSearchableItemActivityIdentifier` from the activity.
    /// False, and nothing changes, for anything that is not one of ours.
    @discardableResult
    public func openSpotlightResult(identifier: String?) -> Bool {
        guard let identifier, let value = AppleAppRoute(spotlightIdentifier: identifier) else { return false }
        appleTrace("spotlight result → media route")
        open(value)
        return true
    }

    /// Opens Search with nothing typed yet — the Mac ⌘F path.
    ///
    /// Separate from `showSearch(_:)` because that one deliberately refuses an
    /// empty query: it serves `openstream://search?query=…` deep links, and a
    /// link with no term in it is a malformed link. A menu command is the
    /// opposite case — an empty field is exactly what it should open.
    public func openSearch() {
        searchQuery = ""
        route = .search("")
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
