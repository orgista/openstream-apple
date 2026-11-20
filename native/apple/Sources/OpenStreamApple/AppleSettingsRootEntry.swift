/// The navigation rows at the head of the Settings root form (iPhone, iPad,
/// Mac, Vision Pro), in order, one inner array per section.
///
/// Backup used to be a bare text row with no icon at the foot of the form,
/// and the owner could not find it on the Mac: "where is the backup option or
/// iCloud sync on macOS? … how do we export?" (2026-09-24). It is now titled
/// for both things it does and sits in its own section right after Sources.
/// Apple TV has no Backup page — its sync is automatic and read-only
/// (`AppleConfigurationSyncPolicy`) — so its split view has no such row.
public enum AppleSettingsRootEntry: String, CaseIterable, Sendable {
    case sources
    case restrictions
    case channels
    case backup

    public static let leadingSections: [[AppleSettingsRootEntry]] = [
        [.sources, .channels, .restrictions],
        [.backup],
    ]

    public var title: String {
        switch self {
        case .sources: "Sources"
        case .channels: "Channel Manager"
        case .restrictions: "Restrictions"
        case .backup: "Backup & Sync"
        }
    }

    public var systemImage: String {
        switch self {
        case .sources: "rectangle.stack.badge.plus"
        case .channels: "list.star"
        case .restrictions: "lock.shield"
        case .backup: "icloud.and.arrow.up"
        }
    }
}
