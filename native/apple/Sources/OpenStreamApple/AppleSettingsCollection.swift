import SwiftUI

/// A settings pane's row collection.
///
/// `Form` on macOS, `List` everywhere else, for the same content.
///
/// Three settings panes were written as a `List` while the other fifteen are
/// `Form`s, and on macOS that difference is visible: a `Form` under
/// `.formStyle(.grouped)` draws its rows in grouped boxes with a chevron on
/// each navigation row, and a `List` draws flat rows with no chevron over a
/// ground two shades darker than the window's — so Sources, reached from a
/// Settings root full of chevrons, had none, inside a 720 pt strip of
/// rgb(30,30,30) on an rgb(40,40,40) window (measured 2026-09-21).
///
/// It stays a `List` off macOS on purpose. tvOS uppercases a `Form`'s section
/// headers and not a `List`'s, and the Sources pane uppercases its own header
/// there to match its neighbours (`AppleSourcesSettingsView`, "Your Sources"). This wrapper changes nothing on any
/// platform but macOS.
struct AppleSettingsCollection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
        #else
        List { content }
        #endif
    }
}
