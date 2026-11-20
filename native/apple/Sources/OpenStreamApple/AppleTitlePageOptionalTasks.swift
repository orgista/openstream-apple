import SwiftUI

/// When the title page's optional work reruns, kept pure for tests.
enum AppleTitlePageOptionalTaskPolicy {
    /// The artwork resolver is a last resort: it runs only once every details
    /// provider has answered (not on the first partial answer) and none of
    /// them brought a poster or backdrop.
    static func resolvesFallbackArtwork(detailsSettled: Bool, hasItemPoster: Bool, hasDetailsArt: Bool) -> Bool {
        detailsSettled && !hasItemPoster && !hasDetailsArt
    }

    static func artworkTaskID(generation: UUID, resolvedMediaID: String?, detailsSettled: Bool) -> String {
        "art:\(generation):\(resolvedMediaID ?? ""):\(detailsSettled)"
    }

    /// Keyed on the load finishing as well as the count, so a series whose
    /// list comes back empty still records once.
    static func episodesTaskID(generation: UUID, loadFinished: Bool, episodeCount: Int) -> String {
        "episodes:\(generation):\(loadFinished):\(episodeCount)"
    }
}

@MainActor
struct AppleTitlePageOptionalTasks: View {
    let enabled: Bool
    let generation: UUID
    let resolvedMediaID: String?
    let detailsSettled: Bool
    let episodesLoadFinished: Bool
    let episodeCount: Int
    let loadWatchProviders: @MainActor @Sendable () async -> Void
    let loadArtwork: @MainActor @Sendable () async -> Void
    let recordEpisodes: @MainActor @Sendable () async -> Void

    var body: some View {
        Color.clear
            .task(id: "watch:\(generation):\(resolvedMediaID ?? "")") {
                guard enabled, resolvedMediaID != nil else { return }
                await loadWatchProviders()
            }
            .task(id: AppleTitlePageOptionalTaskPolicy.artworkTaskID(generation: generation,
                resolvedMediaID: resolvedMediaID, detailsSettled: detailsSettled)) {
                guard enabled else { return }
                await loadArtwork()
            }
            .task(id: AppleTitlePageOptionalTaskPolicy.episodesTaskID(generation: generation,
                loadFinished: episodesLoadFinished, episodeCount: episodeCount)) {
                guard enabled else { return }
                await recordEpisodes()
            }
            .accessibilityHidden(true)
    }
}
