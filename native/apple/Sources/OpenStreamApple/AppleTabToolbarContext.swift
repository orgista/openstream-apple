import SwiftUI

/// Root toolbar actions passed to pushed pages. Title pages keep Search;
/// Refresh belongs to the Discover and Library roots.
struct AppleTabToolbarContext {
    let tab: OpenStreamTab
    /// Read by the page's bar as it draws, not when the page was pushed: a
    /// pushed page's copy of this is not rebuilt with the tab, and a Bool
    /// here left Refresh spinning after the tab had finished.
    let isRefreshing: () -> Bool
    let onSearch: () -> Void
    let onRefresh: () -> Void
}

extension EnvironmentValues {
    @Entry var appleTabToolbar: AppleTabToolbarContext? = nil
}

#if !os(tvOS)
extension View {
    /// The title page's bar: a round ‹ at the leading edge, then Search. ⌘[ and Esc go back too, except while
    /// `backIsBlocked` (a player is up and owns Esc). `pageID` keeps this
    /// page's items apart from the tab's and from a title page under it
    /// (`AppleTabToolbar.scope`).
    func appleTitlePageToolbar(pageID: String, backIsBlocked: Bool = false, onBack: @escaping () -> Void) -> some View {
        modifier(AppleTitlePageToolbar(pageID: pageID, backIsBlocked: backIsBlocked, onBack: onBack))
    }
}

private struct AppleTitlePageToolbar: ViewModifier {
    let pageID: String
    let backIsBlocked: Bool
    let onBack: () -> Void
    @Environment(\.appleTabToolbar) private var tabToolbar

    func body(content: Content) -> some View {
        // Read here, in `body`, so the page redraws when the tab's store
        // changes; the toolbar builder below runs outside that tracking.
        let isRefreshing = tabToolbar?.isRefreshing() ?? false
        return content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                    .accessibilityIdentifier("detail.back")
                    .appleVisionActionTarget()
                }
                if let tabToolbar {
                    AppleTabToolbar(tab: tabToolbar.tab, isRefreshing: isRefreshing,
                                    onSearch: tabToolbar.onSearch, onRefresh: tabToolbar.onRefresh,
                                    scope: "title.\(pageID)", isTitlePage: true)
                }
            }
            #if os(macOS)
            // Esc, which the round button cannot carry beside ⌘[.
            .background {
                Button("Back", action: onBack)
                    .keyboardShortcut(.cancelAction)
                    .disabled(backIsBlocked)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            #endif
    }
}
#endif
