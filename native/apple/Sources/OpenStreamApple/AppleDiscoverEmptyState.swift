import Foundation

/// What Discover says when it has no rows to show.
public enum AppleDiscoverEmptyState: Equatable, Sendable {
    /// No sources at all: Settings is where one is added.
    case noSources
    /// Sources were read and hold nothing to show (all switched off, or
    /// empty).
    case nothingToShow

    public init(sourceCount: Int) {
        self = sourceCount == 0 ? .noSources : .nothingToShow
    }

    /// Whether an empty Discover is still waiting for its first load rather
    /// than empty: sources exist and the first load has not finished yet.
    /// After a restore from iCloud or a relaunch the page said "Nothing to
    /// Show" for a while before the rows came (2026-09-28).
    public static func isStillLoading(sourceCount: Int, hasSettled: Bool) -> Bool {
        sourceCount > 0 && !hasSettled
    }

    public var title: String {
        switch self {
        case .noSources: "No Sources"
        case .nothingToShow: "Nothing to Show"
        }
    }

    /// No Sources has to say that the app ships no content of its own. The
    /// line is not printed under the title: `AppleSourceEmptyState` puts an
    /// (i) beside the title that opens the attribution sheet carrying it
    /// (owner on a6765b2: "just make them (i)").
    public var footnote: String? {
        self == .noSources ? AppleAttribution.noContentDisclaimer : nil
    }

    /// A device with no sources may have a configuration waiting in iCloud.
    /// Not offered where this build cannot reach iCloud at all.
    public func offersICloudRestore(_ availability: AppleICloudSyncAvailability) -> Bool {
        self == .noSources && availability != .notEntitled
    }
}
