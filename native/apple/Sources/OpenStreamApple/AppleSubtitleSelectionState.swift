/// Resolves renderer ownership without confusing an engine deselection for
/// an app sidecar/native-renderer deselection. Track discovery can lag the ID.
enum AppleSubtitleSelectionState {
    static func renderedTrackID(engineTrackID: Int?, appTrackID: Int?, appOwnsRendering: Bool) -> Int? {
        appOwnsRendering ? appTrackID : engineTrackID
    }
}
