#if os(macOS)
import AppKit
import SwiftUI

/// The Mac menu bar.
///
/// Before this the app declared no `.commands` at all, so it shipped with
/// AppKit's defaults and nothing else: the **View menu was completely empty**,
/// the auto-generated "Toggle Sidebar ⌘S" was filed under **Help** (SwiftUI
/// puts it there when the app has no sidebar for it to toggle), there was no
/// Settings item and so no ⌘, and `grep -rn keyboardShortcut Sources/`
/// returned nothing at all (macOS sweep, 2026-09-21).
///
/// Every item here is a thing the app can already do, reached the way a Mac
/// user reaches for it. Nothing new was invented to fill a menu out.
public struct AppleMacMenuCommands: Commands {
    private let commands: AppleMacCommandCenter

    public init(commands: AppleMacCommandCenter = .shared) {
        self.commands = commands
        AppleMacFullScreenObserver.start(updating: commands)
    }

    public var body: some Commands {
        // ⌘, — the one shortcut a Mac user will try before any other. The app
        // has no `Settings` scene (Settings is a tab of the main window, the
        // same as on every other platform), and without a `Settings` scene
        // SwiftUI leaves the app menu with no Preferences item, so this
        // replaces the empty group rather than adding to it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { commands.send(.selectTab(.settings)) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(commands.isPlayerOnStage)
        }

        // The View menu. `replacing:` rather than `after:` on purpose: the
        // group being replaced is the one that was generating "Toggle Sidebar"
        // and stranding it in Help.
        CommandGroup(replacing: .sidebar) {
            ForEach(AppleMacTabTarget.allCases, id: \.self) { target in
                Button(target.title) { commands.send(.selectTab(target)) }
                    .keyboardShortcut(
                        KeyEquivalent(target.shortcutCharacter),
                        modifiers: .command
                    )
                    .disabled(!commands.availableTabs.contains(target) || commands.isPlayerOnStage)
            }
            Divider()
            // The toolbar's Refresh, by its Mac key (the Apple TV app and
            // Safari both reload on ⌘R). Disabled on the tabs without one.
            Button("Refresh") { commands.requestRefresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!commands.canRefresh)
            Divider()
            // 16:9 on an ultrawide display leaves bars at the sides; this
            // crops to fill instead. Only while something is playing.
            Toggle("Zoom to Fill", isOn: Binding(
                get: { commands.zoomToFill },
                set: { commands.zoomToFill = $0 }
            ))
            .keyboardShortcut("z", modifiers: [.option, .command])
            .disabled(!commands.canControlPlayback)
            // AppKit's own item, reproduced (N56): the same "Enter Full
            // Screen"/"Exit Full Screen" wording, the same ⌃⌘F, the same
            // `toggleFullScreen:` sent up the responder chain to the key
            // window. It was "Toggle Full Screen", a title no Mac app uses.
            // The app keeps the item rather than leaving it to AppKit because
            // AppKit's is added lazily (it never appeared in a dump of this
            // menu bar, even after an update pass), and
            // `AppleMacFullScreenObserver` opts out of that insertion so the
            // menu can never show both.
            Button(AppleMacFullScreenItem.title(isFullScreen: commands.isFullScreen), action: toggleFullScreen)
                .keyboardShortcut("f", modifiers: [.control, .command])
        }

        // The app has no help book, so "OpenStream Help ⌘?" opened nothing —
        // and SwiftUI was also appending its auto-generated "Toggle Sidebar"
        // to this menu, where it made no sense at all: this app has no
        // sidebar, and the item stayed in Help even after the View menu was
        // populated (verified against the real `NSApp.mainMenu`, 2026-09-21).
        // Replacing the group with nothing removes both.
        CommandGroup(replacing: .help) {}

        // Search is a page pushed from Discover on macOS, not a tab, so ⌘F is
        // the only way to it that does not start with finding a toolbar glyph.
        CommandGroup(after: .textEditing) {
            Button("Search") { commands.send(.openSearch) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(commands.isPlayerOnStage)
        }

        // Named for the menu the Apple TV app on the Mac uses, because that
        // app is the reference for how playback feels here (AGENTS.md §4.1).
        //
        // Every item is disabled unless a player has installed its controls.
        // That is not tidiness: a menu key equivalent is matched before the
        // responder chain, so a live ␣ item would swallow the space bar in
        // every text field in Settings. A disabled item does not claim its
        // key equivalent.
        CommandMenu("Controls") {
            Button("Play/Pause") { commands.perform(.togglePlayPause) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!commands.canControlPlayback)
            Button("Skip Forward") { commands.perform(.skipForward) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!commands.canControlPlayback)
            Button("Skip Back") { commands.perform(.skipBackward) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!commands.canControlPlayback)
            Divider()
            // The Apple TV app's titles and keys, read from its own menu
            // (`TV.app` MainMenu.nib: "Increase Volume" ⌘↑, "Decrease
            // Volume" ⌘↓). It has no Mute item; ⌥⌘↓ is the Music app's
            // old mute key and sits beside the other two.
            Button("Increase Volume") { commands.perform(.volumeUp) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!commands.canControlPlayback)
            Button("Decrease Volume") { commands.perform(.volumeDown) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!commands.canControlPlayback)
            Button("Mute") { commands.perform(.toggleMute) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(!commands.canControlPlayback)
        }
    }

    /// Up the responder chain, as AppKit's own item sends it: the key window
    /// first — a player opened in its own window is the one that goes full
    /// screen — then the main window.
    private func toggleFullScreen() {
        NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
    }
}

/// Keeps `AppleMacCommandCenter.isFullScreen` in step with the key window,
/// for the View menu's Enter/Exit Full Screen title.
@MainActor
enum AppleMacFullScreenObserver {
    private static var observers: [NSObjectProtocol] = []

    static func start(updating commands: AppleMacCommandCenter) {
        guard observers.isEmpty else { return }
        // AppKit adds its own "Enter Full Screen" to a View menu that has no
        // `toggleFullScreen:` item, and SwiftUI's buttons do not carry that
        // selector, so without this the menu could show the item twice. The
        // documented opt-out, the one browsers set for the same reason.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        let names: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let window = NSApp.keyWindow ?? NSApp.mainWindow
                    commands.isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
                }
            }
        }
    }
}
#endif
