import AVFoundation
import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// How each platform puts the player on screen. Every entry point — hero
/// Play, title page Play, an episode, a local file, a media server, Add Files —
/// goes through `AppleStremioPlayerPresentationModifier`, which asks this.
enum AppleMediaPlayerPresentationStyle: Equatable {
    /// The player takes over the window it was opened from (macOS,
    /// visionOS). On Vision Pro it used to open a second "Player" window;
    /// the owner wants it inside the app, the way other apps play
    /// (2026-10-07). See `AppleVisionPlayerStage`.
    case windowStage
    /// A full-screen cover (iOS, iPadOS, tvOS).
    case fullScreenCover

    static var current: Self {
        #if os(macOS) || os(visionOS)
        .windowStage
        #else
        .fullScreenCover
        #endif
    }
}

/// The Mac player's picture: the whole window, and the film's own shape.
///
/// It used to be a sheet with a 1024 x 576 floor, a 16:9 card floating over
/// the page (owner, 2026-09-24: "should take over the current app as the
/// player"). The frame is the container, full stop — no aspect box, no
/// minimum, no padding — and AVKit letterboxes inside it, so a 2.39:1 film
/// fills an ultrawide display edge to edge and 16:9 is the one that shows
/// bars. View ▸ Zoom to Fill crops instead.
enum AppleMacPlayerFramePolicy {
    static func playerFrame(in container: CGSize) -> CGRect {
        CGRect(origin: .zero, size: container)
    }

    static func videoGravity(zoomToFill: Bool) -> AVLayerVideoGravity {
        zoomToFill ? .resizeAspectFill : .resizeAspect
    }
}

/// The keys that leave the Mac player while it covers a window.
enum AppleMacPlayerKeyPolicy {
    enum Key: Equatable {
        case escape
        case commandW
        case other
    }

    /// Esc and ⌘W close the player, not the window. A sheet over the player
    /// (Other sources, the failure alert) keeps its own Esc, and ⌘W with any
    /// other modifier is some other command.
    static func closesPlayer(_ key: Key, windowHasSheet: Bool) -> Bool {
        guard !windowHasSheet else { return false }
        return key != .other
    }

    #if os(macOS)
    static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Key {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == 53, flags.isEmpty { return .escape }
        if flags == .command, characters?.lowercased() == "w" { return .commandW }
        return .other
    }
    #endif
}

#if os(macOS)
/// The one player a Mac window shows, drawn over the whole window by the
/// root view (`appleMacPlayerStage()`).
///
/// A page hands its presentation over and gets a callback when the player
/// closes, which is when it clears its own binding — so the page underneath
/// never leaves the window and comes back exactly as it was: scroll
/// position, selection, the season menu, everything.
@MainActor
@Observable
final class AppleMacPlayerStage {
    private(set) var presentation: AppleStremioPlayerPresentation?
    @ObservationIgnored private var onDismiss: (() -> Void)?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    /// The title bar as it was before the player covered it.
    @ObservationIgnored private var savedChrome: SavedChrome?

    private struct SavedChrome {
        let toolbarVisible: Bool
        let titlebarAppearsTransparent: Bool
        let titleVisibility: NSWindow.TitleVisibility
    }
    @ObservationIgnored private let commands: AppleMacCommandCenter

    init(commands: AppleMacCommandCenter = .shared) {
        self.commands = commands
    }

    var isPresenting: Bool { presentation != nil }

    /// Shows `presentation`, replacing any player already up (whose page is
    /// told it closed).
    func present(_ presentation: AppleStremioPlayerPresentation, onDismiss: @escaping () -> Void) {
        guard self.presentation?.id != presentation.id else { return }
        let replaced = self.onDismiss
        self.presentation = presentation
        self.onDismiss = onDismiss
        commands.isPlayerOnStage = true
        installKeyMonitor()
        coverTitleBar()
        replaced?()
    }

    /// Closes the player. With an `id`, only if that player is still the one
    /// up, so a page clearing a presentation that was already replaced
    /// cannot close its successor.
    func dismiss(id: UUID? = nil) {
        guard let current = presentation, id == nil || id == current.id else { return }
        presentation = nil
        let callback = onDismiss
        onDismiss = nil
        commands.isPlayerOnStage = false
        removeKeyMonitor()
        restoreTitleBar()
        callback?()
    }

    /// Esc and ⌘W, for this window only. A local monitor sees the key before
    /// the menu bar does, which is what makes ⌘W close the player rather than
    /// the window, and before the page's focused button, which is what makes
    /// Esc work whatever the pointer last clicked.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit calls local monitors on the main thread.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isPresenting,
                      let window = self.window, event.window === window else { return false }
                let key = AppleMacPlayerKeyPolicy.key(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      characters: event.charactersIgnoringModifiers)
                guard AppleMacPlayerKeyPolicy.closesPlayer(key, windowHasSheet: window.attachedSheet != nil)
                else { return false }
                self.dismiss()
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Puts the toolbar away — the tab picker and the page's buttons — and
    /// lets the picture run under a clear title bar, the way QuickTime and the
    /// TV app play. Done on the window rather than with SwiftUI's
    /// `.toolbar(.hidden, for: .windowToolbar)`, which hides the whole title
    /// bar container and the traffic lights with it (measured on the window:
    /// `NSTitlebarContainerView hidden=true`, 2026-09-24).
    private func coverTitleBar() {
        guard savedChrome == nil, let window else { return }
        savedChrome = SavedChrome(toolbarVisible: window.toolbar?.isVisible ?? false,
                                  titlebarAppearsTransparent: window.titlebarAppearsTransparent,
                                  titleVisibility: window.titleVisibility)
        window.toolbar?.isVisible = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }

    private func restoreTitleBar() {
        guard let savedChrome, let window else { return }
        self.savedChrome = nil
        window.toolbar?.isVisible = savedChrome.toolbarVisible
        window.titlebarAppearsTransparent = savedChrome.titlebarAppearsTransparent
        window.titleVisibility = savedChrome.titleVisibility
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    isolated deinit {
        removeKeyMonitor()
    }
}

extension View {
    /// Gives this window a player stage: the player over everything, edge to
    /// edge and under the title bar, with the toolbar and the tab bar put
    /// away while it plays (`AppleMacPlayerStage.coverTitleBar`). The traffic lights stay AppKit's and keep working,
    /// so ⌃⌘F and the green button still take the window full screen.
    func appleMacPlayerStage(_ stage: AppleMacPlayerStage) -> some View {
        modifier(AppleMacPlayerStageHost(stage: stage))
    }
}

private struct AppleMacPlayerStageHost: ViewModifier {
    let stage: AppleMacPlayerStage

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(stage.isPresenting)
            .overlay {
                if let presentation = stage.presentation {
                    // The picture ignores the safe area itself and runs under
                    // the title bar; the player's own buttons keep to it, so
                    // none sits under the traffic lights.
                    AppleStremioPlayerView(presentation: presentation)
                        .id(presentation.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.ignoresSafeArea())
                }
            }
            .background {
                AppleMacWindowReader { stage.window = $0 }
            }
            .environment(stage)
    }
}

/// Hands back the window a view is in, once it is in one.
private struct AppleMacWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The page's end: hands the presentation to the window's stage and clears
/// the page's binding when the player closes.
struct AppleMacPlayerStagePresenter: ViewModifier {
    @Binding var presentation: AppleStremioPlayerPresentation?
    @Environment(AppleMacPlayerStage.self) private var stage: AppleMacPlayerStage?
    /// A window with no stage (a debug fixture window) gets its own, over
    /// the presenting view.
    @State private var fallbackStage = AppleMacPlayerStage()

    func body(content: Content) -> some View {
        Group {
            if stage == nil {
                content.appleMacPlayerStage(fallbackStage)
            } else {
                content
            }
        }
        .onChange(of: presentation?.id, initial: true) { previous, _ in
            let target = stage ?? fallbackStage
            if let presentation {
                target.present(presentation) { [binding = $presentation, id = presentation.id] in
                    if binding.wrappedValue?.id == id { binding.wrappedValue = nil }
                }
            } else if let previous {
                // Only the player this page opened; another page's is not ours.
                target.dismiss(id: previous)
            }
        }
    }
}
#endif

typealias AppleStremioPlayerPresentationStyle = AppleMediaPlayerPresentationStyle
