import CoreGraphics

/// The numbers the Mac window's own chrome is laid out with.
///
/// Its own file for the same reason `AppleTVChromeMetrics` has one: every Mac
/// screen has to agree on them, and a constant repeated at two call sites
/// drifts. tvOS reasons in safe-zone insets and iOS in size classes; a Mac
/// window is resizable with no safe area at all, so the numbers it needs are a
/// readable column width and the width at which the detail page earns the
/// wide, landscape layout.
public enum AppleMacChromeMetrics {
    /// How wide a settings form is allowed to get.
    ///
    /// Not the 560 pt the old `#else` branch used — that is a phone column, and
    /// centred in a 1280 pt window it read as a narrow strip of rows with the
    /// page title stranded in the titlebar above it. 720 is what the visionOS
    /// branch already settles on for the same content at a comparable
    /// distance, so the two agree rather than each picking a number.
    public static let settingsColumnWidth: CGFloat = 720

    /// The window width at which the detail page takes the iPad/Vision
    /// landscape layout — full-bleed hero with the title, metadata and actions
    /// overlaid — instead of the stacked portrait one. The same 760 pt the
    /// visionOS branch uses.
    public static let regularLayoutMinimumWidth: CGFloat = 760

    /// Whether a window of this size gets the wide layout. A Mac window can be
    /// dragged to any shape, including taller than it is wide, and a portrait
    /// window wants the portrait layout however large it is.
    public static func isRegularLayout(viewport: CGSize) -> Bool {
        viewport.width >= regularLayoutMinimumWidth && viewport.width > viewport.height
    }
}
