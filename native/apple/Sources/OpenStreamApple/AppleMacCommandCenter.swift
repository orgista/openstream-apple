import Foundation
import Observation

/// What a Mac menu item asks the app to do.
///
/// The menu bar is declared in the app target, which reaches this package
/// through its public API and cannot see `OpenStreamTab`, so the tab a command
/// selects is named again as `AppleMacTabTarget`. The mapping back is
/// `OpenStreamTab(macTarget:)`, and it is tested: a View menu item that
/// selected a tab the bar does not currently show would be a dead command, and
/// the Live tab really can be switched off in Settings.
public enum AppleMacCommand: Equatable, Sendable {
    case selectTab(AppleMacTabTarget)
    case openSearch
    case togglePlayPause
    case skipForward
    case skipBackward
    case volumeUp
    case volumeDown
    case toggleMute
}

/// The four tabs a Mac menu item can select, in menu order.
public enum AppleMacTabTarget: String, CaseIterable, Sendable {
    case discover
    case library
    case live
    case settings

    public var title: String {
        switch self {
        case .discover: "Discover"
        case .library: "Library"
        case .live: "Live"
        case .settings: "Settings"
        }
    }

    /// ⌘1 … ⌘4, the numbering every Mac app with a fixed set of views uses.
    /// Derived from the case order rather than written out, so a fifth tab
    /// cannot be given a number that is already taken.
    public var shortcutCharacter: Character {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return Character(String(index + 1))
    }
}

/// How the player answers the Controls menu.
///
/// Values, not a reference to the coordinator: the menu is built once for the
/// whole app and there is one coordinator per playback session, so the player
/// hands over its closures while it is on screen and takes them back when it
/// leaves.
@MainActor
public struct AppleMacPlaybackControls {
    public let id: UUID
    let togglePlayPause: () -> Void
    let skipForward: () -> Void
    let skipBackward: () -> Void
    let volumeUp: () -> Void
    let volumeDown: () -> Void
    let toggleMute: () -> Void

    public init(
        id: UUID = UUID(),
        togglePlayPause: @escaping () -> Void,
        skipForward: @escaping () -> Void,
        skipBackward: @escaping () -> Void,
        volumeUp: @escaping () -> Void = {},
        volumeDown: @escaping () -> Void = {},
        toggleMute: @escaping () -> Void = {}
    ) {
        self.id = id
        self.togglePlayPause = togglePlayPause
        self.skipForward = skipForward
        self.skipBackward = skipBackward
        self.volumeUp = volumeUp
        self.volumeDown = volumeDown
        self.toggleMute = toggleMute
    }
}

/// Controls ▸ Increase/Decrease Volume, as values.
///
/// Tenths, snapped, so ten presses from silence land on exactly full volume
/// rather than 0.99999994 short of it, and a press past either end stays at
/// that end.
public enum AppleMacVolumeStep {
    public static let step: Float = 0.1

    public static func raised(_ volume: Float) -> Float { snapped(volume + step) }
    public static func lowered(_ volume: Float) -> Float { snapped(volume - step) }

    private static func snapped(_ volume: Float) -> Float {
        min(1, max(0, (volume * 10).rounded() / 10))
    }
}

/// View ▸ Enter/Exit Full Screen, worded the way AppKit's own item is.
public enum AppleMacFullScreenItem {
    public static func title(isFullScreen: Bool) -> String {
        isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
    }
}

/// The one place the Mac menu bar and the app's views meet.
///
/// The root view watches `revision` and acts on `command`; the player installs
/// and removes `playback`. Nothing else holds state, so a command that no view
/// is listening for is simply dropped rather than queued up to fire later.
@MainActor
@Observable
public final class AppleMacCommandCenter {
    public static let shared = AppleMacCommandCenter()

    public private(set) var command: AppleMacCommand?
    public private(set) var revision = 0

    /// Installed by the player while it is on screen, cleared when it leaves.
    ///
    /// This does two jobs, and the second one is the important one. A menu
    /// item's key equivalent is matched *before* the responder chain sees the
    /// key, so a live "Play/Pause ␣" item would make it impossible to type a
    /// space into any text field in the app — a server address, an API key,
    /// a backup passphrase. A disabled menu item does not claim its key
    /// equivalent, so gating the Controls menu on this being non-nil is what
    /// lets the space bar be the play/pause key at all.
    public private(set) var playback: AppleMacPlaybackControls?

    /// Which View-menu tab items are live.
    ///
    /// Discover, Library and Live each have a toggle in Settings, so the bar
    /// does not always show all four. A menu item for a hidden tab that
    /// silently landed the viewer on a different one is worse than a greyed
    /// out item, which is the answer every Mac app gives for a view that is
    /// not available.
    public var availableTabs: Set<AppleMacTabTarget> = Set(AppleMacTabTarget.allCases)

    /// View ▸ Zoom to Fill: the picture fills the window and its edges are
    /// cropped, for 16:9 films on an ultrawide display. Off by default and
    /// kept for the session, not saved — the next film may be 2.39:1.
    public var zoomToFill = false

    /// Whether the key window is in full screen, so View ▸ Enter Full Screen
    /// can read "Exit Full Screen" the way AppKit's own item does. Kept by the
    /// menu's window observer.
    public internal(set) var isFullScreen = false

    /// True while a player covers a window. The tab bar is hidden then, so
    /// the View menu's tab items step aside rather than switch the page under
    /// the picture.
    public internal(set) var isPlayerOnStage = false

    /// The tab the window shows, kept by the root view, so View ▸ Refresh
    /// knows whose content to reload.
    public var selectedTab: AppleMacTabTarget?

    /// View ▸ Refresh ⌘R, the Mac path to the toolbar's Refresh button
    /// (N54: the button had no key equivalent and no menu item). The tab
    /// that owns the button watches `refreshRevision` and reloads when
    /// `refreshTarget` is itself.
    public private(set) var refreshTarget: AppleMacTabTarget?
    public private(set) var refreshRevision = 0

    public init() {}

    /// Refresh is live on the tabs whose toolbar has the button
    /// (`AppleTabToolbarPolicy`), and not while a player covers the window.
    public var canRefresh: Bool {
        guard let selectedTab, !isPlayerOnStage else { return false }
        return AppleTabToolbarPolicy.items(for: OpenStreamTab(macTarget: selectedTab), isTV: false).contains(.refresh)
    }

    public func requestRefresh() {
        guard canRefresh, let selectedTab else { return }
        refreshTarget = selectedTab
        refreshRevision &+= 1
    }

    /// Whether the Controls menu is live. The menu reads this directly.
    public var canControlPlayback: Bool { playback != nil }

    public func send(_ command: AppleMacCommand) {
        self.command = command
        revision &+= 1
    }

    public func install(_ controls: AppleMacPlaybackControls) {
        playback = controls
    }

    /// Removes the controls only if they are still the ones that were
    /// installed. Two players can overlap for a frame while one is dismissed
    /// over the other, and an unconditional clear would leave the menu dead
    /// for the player that is actually on screen.
    public func remove(id: UUID) {
        guard playback?.id == id else { return }
        playback = nil
    }

    public func perform(_ command: AppleMacCommand) {
        guard let playback else { return }
        switch command {
        case .togglePlayPause: playback.togglePlayPause()
        case .skipForward: playback.skipForward()
        case .skipBackward: playback.skipBackward()
        case .volumeUp: playback.volumeUp()
        case .volumeDown: playback.volumeDown()
        case .toggleMute: playback.toggleMute()
        case .selectTab, .openSearch: break
        }
    }
}

extension OpenStreamTab {
    init(macTarget: AppleMacTabTarget) {
        switch macTarget {
        case .discover: self = .home
        case .library: self = .library
        case .live: self = .live
        case .settings: self = .settings
        }
    }
}

extension AppleMacTabTarget {
    /// Nil for the tvOS-only Search tab, which is never in a Mac menu — on
    /// macOS Search is a page pushed from Discover and has its own ⌘F item.
    init?(tab: OpenStreamTab) {
        switch tab {
        case .home: self = .discover
        case .library: self = .library
        case .live: self = .live
        case .settings: self = .settings
        case .search: return nil
        }
    }
}
