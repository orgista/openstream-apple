import Foundation

@MainActor
struct ApplePlaybackSourceOption: Identifiable {
    let id: URL
    let title: String
    let detail: String
    let prepare: () async throws -> AppleStremioPlayerPresentation
}

/// The in-player "Other sources" sheet's two views of the same candidates.
///
/// `grouped` is what the sheet shows by default — a handful of quality
/// choices via `AppleStreamSourceGrouping` — while `all` stays the full,
/// unfiltered candidate list in resolver order. The automatic-fallback loop
/// in `AppleStremioPlayerView` walks `all`, not `grouped`: collapsing the
/// sheet's default view must not also shrink how many sources playback
/// retries after a failure. `all` also backs the sheet's "Show all sources"
/// toggle, so a specific stream stays reachable when the grouped choice
/// isn't the one a viewer actually wants.
@MainActor
struct ApplePlaybackSourceOptions {
    let grouped: [ApplePlaybackSourceOption]
    let all: [ApplePlaybackSourceOption]
}
