import Foundation

/// When the Live guide shows a moving preview of the channel under focus.
///
/// The guide showed a logo and a description and nothing else, so browsing it
/// told you what was on but never what it looked like (owner 2026-09-14:
/// "there is no preview of the channel"). A preview costs a second live
/// connection, so it is dwell-gated: the channel has to hold focus before
/// anything starts, which means running the rail does not open and abandon a
/// stream per row.
///
/// Plain values rather than the tvOS focus enum, so the rules are testable on
/// any platform.
public enum AppleTVGuidePreviewPolicy: Sendable {
    /// How long a channel holds focus before its preview starts. Long enough
    /// that scrolling past a row never starts one, short enough that stopping
    /// to read a row brings the picture up on its own.
    public static let dwell: Duration = .milliseconds(1200)

    /// The channel to preview, or nil for "show the logo".
    ///
    /// - Parameters:
    ///   - focusedChannelID: the rail cell under focus, if any.
    ///   - focusedCellChannelID: the channel of the focused programme cell, if
    ///     focus is in the timeline instead of the rail.
    ///   - isEnabled: the viewer's autoplay preference. A viewer who turned
    ///     trailer autoplay off does not want a guide that plays by itself
    ///     either, so the two share one switch rather than adding a setting.
    ///   - isPlayerOpen: nothing previews behind the full-screen player.
    public static func target(
        focusedChannelID: String?,
        focusedCellChannelID: String? = nil,
        isEnabled: Bool,
        isPlayerOpen: Bool = false
    ) -> String? {
        guard isEnabled, !isPlayerOpen else { return nil }
        if let focusedChannelID, !focusedChannelID.isEmpty { return focusedChannelID }
        if let focusedCellChannelID, !focusedCellChannelID.isEmpty { return focusedCellChannelID }
        return nil
    }
}
