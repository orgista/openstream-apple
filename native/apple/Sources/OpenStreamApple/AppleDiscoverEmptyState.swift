import Foundation

/// What Discover says when it has no rows to show.
///
/// "Nothing to Show" used to cover every case with sources, including the one
/// where the saved catalog could not be read at all (a source address the
/// keychain would not give back, every catalog request failing). The page
/// looked like an empty catalog and offered only Settings (N54 #14).
public enum AppleDiscoverEmptyState: Equatable, Sendable {
    /// No sources at all: Settings is where one is added.
    case noSources
    /// Sources exist but reading them failed: say so, and offer a reload.
    case couldNotLoad
    /// Sources were read and hold nothing to show (all switched off, or
    /// catalogs that came back empty).
    case nothingToShow

    public init(sourceCount: Int, catalogFailureCount: Int, hasSourceError: Bool) {
        if sourceCount == 0 {
            self = .noSources
        } else if catalogFailureCount > 0 || hasSourceError {
            self = .couldNotLoad
        } else {
            self = .nothingToShow
        }
    }

    /// Only active catalog sources can turn a source credential failure into a
    /// catalog error. Live TV and network credentials belong to their own flows;
    /// retained add-on payloads are absent from `sources` in App Store builds.
    public init(sources: [AppleSource], catalogFailureCount: Int, hasSourceError: Bool) {
        self.init(sourceCount: sources.count, catalogFailureCount: catalogFailureCount,
                  hasSourceError: hasSourceError && sources.contains { $0.isAddon && $0.isEnabled })
    }

    /// Whether an empty Discover is still waiting for its catalogs rather
    /// than empty: sources exist and either a load is running or the
    /// current sources have not finished their first refresh yet. After a
    /// restore from iCloud or a relaunch the page said "Nothing to Show" for
    /// a while before the rows came (2026-09-28).
    public static func isStillLoading(sourceCount: Int, isLoading: Bool, hasSettled: Bool) -> Bool {
        sourceCount > 0 && (isLoading || !hasSettled)
    }

    public var title: String {
        switch self {
        case .noSources: "No Sources"
        case .couldNotLoad: "Couldn't Load Your Catalogs"
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

    /// Only a failure is worth retrying; reloading an empty or missing
    /// catalog would leave the page exactly as it was.
    public var offersRetry: Bool { self == .couldNotLoad }

    /// A device with no sources may have a configuration waiting in iCloud.
    /// Not offered where this build cannot reach iCloud at all.
    public func offersICloudRestore(_ availability: AppleICloudSyncAvailability) -> Bool {
        self == .noSources && availability != .notEntitled
    }
}
