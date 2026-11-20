import Foundation

/// SF Symbol and spoken action, shared by title controls on every surface.
enum AppleSemanticAction {
    struct Presentation: Equatable, Sendable {
        let symbol: String
        let label: String
    }
    static let play = Presentation(symbol: "play.fill", label: "Play")
    static let info = Presentation(symbol: "info.circle", label: "Details")
    static let more = Presentation(symbol: "ellipsis", label: "More")

    static func myList(saved: Bool) -> Presentation {
        Presentation(symbol: saved ? "checkmark" : "plus", label: saved ? "Remove from My List" : "Add to My List")
    }

    static func rating(_ value: AppleTitleRating?, selected: Bool) -> Presentation {
        let symbol: String
        switch value {
        case .down: symbol = selected ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        case .up: symbol = selected ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .doubleUp: symbol = selected ? "heart.fill" : "heart"
        case .none, .some(.none): symbol = "hand.thumbsup"
        }
        return Presentation(symbol: symbol, label: value?.title ?? "Rate")
    }

    enum DownloadState { case idle, preparing, active, paused, completed, retry }
    static func download(_ state: DownloadState) -> Presentation {
        switch state {
        case .idle: Presentation(symbol: "arrow.down.circle", label: "Download")
        case .preparing: Presentation(symbol: "arrow.down.circle", label: "Preparing")
        case .active: Presentation(symbol: "arrow.down.circle", label: "Downloading")
        case .paused: Presentation(symbol: "pause.circle", label: "Resume Download")
        case .completed: Presentation(symbol: "arrow.down.circle.fill", label: "Downloaded")
        case .retry: Presentation(symbol: "arrow.clockwise", label: "Retry Download")
        }
    }
}
