import Foundation

/// What the detail page's Episodes section shows.
///
/// "Not available" is a claim about a finished load, so it needs positive
/// evidence that the current title's episode fetch completed. A load that has
/// not started yet, is in flight, or was superseded by a newer one keeps the
/// placeholder rows up instead.
enum AppleEpisodeListPresentation: Equatable {
    case loading
    case episodes
    case unavailable

    static func resolve(
        episodeCount: Int,
        isLoading: Bool,
        hasFinishedLoading: Bool
    ) -> AppleEpisodeListPresentation {
        if episodeCount > 0 { return .episodes }
        if isLoading || !hasFinishedLoading { return .loading }
        return .unavailable
    }
}
