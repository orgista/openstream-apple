import CoreGraphics
import Foundation

/// The Apple TV Settings sections in sidebar order (rework plan task 7). The
/// list is the left column of the split view; the selected section's form is
/// drawn on the right. Library has no row of its own: its tab toggle lives in
/// the Discover pane because Library is the Discover catalogue seen by shelf.
public enum AppleTVSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case sources
    case channels
    case liveTV
    case discover
    case services
    case playback
    case privacy
    case storage
    case about

    public var id: String { rawValue }

    public static let defaultSelection: AppleTVSettingsSection = .sources

    public var title: String {
        switch self {
        case .sources: "Sources"
        case .channels: "Channel Manager"
        case .liveTV: "Live TV"
        case .discover: "Discover"
        case .services: "Services"
        case .playback: "Playback"
        case .privacy: "Privacy"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .sources: "rectangle.stack.badge.plus"
        case .channels: "list.star"
        case .liveTV: "dot.radiowaves.left.and.right"
        case .discover: "square.grid.2x2"
        case .services: "puzzlepiece.extension"
        case .playback: "play.circle"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

/// Apple TV Settings geometry from the rework plan (FEEDBACK section C): a
/// 1920 pt wide canvas with the 80 pt safe inset, a 420 pt sections list, the
/// detail pane beside it, 72 pt rows with Body 29 text and 16 pt between an
/// icon and its title, Title 3 (48 pt) headers, Caption 1 (25 pt) field labels
/// and 220x66 Callout 31 pills. Plain data so the layout can be asserted
/// without a view.
public struct AppleTVSettingsMetrics: Sendable, Equatable {
    public static let standard = AppleTVSettingsMetrics()

    public var screenWidth: CGFloat = 1920
    public var horizontalSafeInset: CGFloat = 80

    // Split view
    public var sidebarWidth: CGFloat = 420
    public var columnSpacing: CGFloat = 40
    public var rowHeight: CGFloat = 72
    public var rowSpacing: CGFloat = 8
    public var rowCornerRadius: CGFloat = 14
    public var rowHorizontalPadding: CGFloat = 24
    public var iconSpacing: CGFloat = 16
    public var iconColumnWidth: CGFloat = 40
    public var formMaximumWidth: CGFloat = 1000

    // Forms. The Xtream form is the tallest — type, name, endpoint, username,
    // password, then the actions — and at 28/44 it measured about 1050 pt
    // against a 1020 pt content area, so Save and Test Connection rested
    // half-clipped by the bottom edge until the viewer moved focus down
    // (review 2026-09-14, U4). These fit it on screen with the rhythm intact.
    public var formColumnWidth: CGFloat = 900
    public var fieldSpacing: CGFloat = 20
    public var labelSpacing: CGFloat = 8
    public var groupSpacing: CGFloat = 32
    public var pillSize = CGSize(width: 220, height: 66)
    public var choicePillHeight: CGFloat = 56
    public var pillSpacing: CGFloat = 24

    // tvOS SF Pro text styles: Title 3 48, Callout 31, Body 29, Caption 1 25.
    public var headerFontSize: CGFloat = 48
    public var pillFontSize: CGFloat = 31
    public var bodyFontSize: CGFloat = 29
    public var captionFontSize: CGFloat = 25

    public init() {}

    /// Where the sections list starts: the safe inset, so x = 80.
    public var sidebarMinX: CGFloat { horizontalSafeInset }

    /// Where the detail pane starts once the list and the gap are laid out.
    public var detailMinX: CGFloat { horizontalSafeInset + sidebarWidth + columnSpacing }

    /// The detail pane's width inside the trailing safe inset.
    public var detailWidth: CGFloat { screenWidth - detailMinX - horizontalSafeInset }
}
