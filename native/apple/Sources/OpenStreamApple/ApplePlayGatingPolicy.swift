import Foundation

/// Decides how much metadata the detail page has to wait for before Play is
/// usable. Play needs a canonical id (and, for a series, an episode); it does
/// not need preview art or TMDB enrichment.
enum ApplePlayGatingPolicy {
    /// The canonical `tt…` id the catalog item already carries, if any. When
    /// this is non-nil no meta add-on round trip is needed to start playback.
    static func canonicalMediaID(_ mediaID: String) -> String? {
        AppleStremioMetadataClient.canonicalMediaID(mediaID)
    }

    /// True when the item needs a meta add-on round trip before Play works.
    static func requiresIdentifierResolution(mediaID: String) -> Bool {
        canonicalMediaID(mediaID) == nil
    }

    /// Whether the detail page must keep showing "Loading" on Play when it
    /// first appears. An item that already carries a canonical id is ready as
    /// soon as it is on screen; a series additionally needs an episode before
    /// Play is enabled, but the label stays "Play".
    static func isPreparingOnAppear(mediaID: String) -> Bool {
        requiresIdentifierResolution(mediaID: mediaID)
    }

    /// The episode Play should target when nothing has been watched yet: the
    /// first episode of the first season in display order.
    static func defaultEpisodeID(episodes: [AppleStremioEpisode]) -> String? {
        AppleStremioEpisodePolicy
            .episodes(in: AppleStremioEpisodePolicy.initialSeason(in: episodes), from: episodes)
            .first?.id
    }
}
