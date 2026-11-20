import Foundation

/// One of a title's other playable files, which the player tries in order
/// after the one it started with fails.
@MainActor
struct ApplePlaybackSourceOption: Identifiable {
    let id: URL
    /// Builds the player for this source at its saved position.
    let prepare: () async throws -> AppleMediaPlayerPresentation
}
