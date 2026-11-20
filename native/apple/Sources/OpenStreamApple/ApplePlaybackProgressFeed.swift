import Foundation
import Observation

/// Playback progress a view can observe. `ApplePlaybackStore` is a thin
/// wrapper over UserDefaults, so a label that read it in `body` — the iPhone
/// hero's "Resume S1, E3" — was never told a save happened and stayed stale
/// after playback until the page changed. Every save and clear bumps
/// `revision`; reading progress through here registers that dependency, the
/// same Observation path Continue Watching's shelf takes through the media
/// index. No polling.
@MainActor
@Observable
public final class ApplePlaybackProgressFeed {
    public static let shared = ApplePlaybackProgressFeed()

    /// Moves on every save or clear, in any `ApplePlaybackStore`.
    public private(set) var revision = 0

    public static let continueWatchingChangeNotification = Notification.Name("OpenStreamContinueWatchingChanged")

    private init() {}

    /// `store`'s progress for `mediaID`, read so the caller is invalidated by
    /// the next save or clear.
    public func progress(for mediaID: String, in store: ApplePlaybackStore = ApplePlaybackStore()) -> ApplePlaybackProgress? {
        _ = revision
        return store.progress(for: mediaID)
    }

    /// The finished titles among `mediaIDs`, read so the caller is
    /// invalidated when one is finished, marked or unmarked.
    public func completedMediaIDs(among mediaIDs: [String], in store: ApplePlaybackStore = ApplePlaybackStore()) -> Set<String> {
        _ = revision
        return store.completedMediaIDs(among: mediaIDs)
    }

    func storeDidChange() {
        revision &+= 1
    }
}
