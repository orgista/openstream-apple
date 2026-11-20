import SwiftUI

/// Root toolbar actions passed to pushed pages. iPad, Mac and Vision title pages keep Search;
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
    /// The title page's Back control. ⌘[ and Esc go back too, except while
    /// `backIsBlocked` (a player is up and owns Esc). `pageID` keeps this
    /// page's items apart from the tab's and from a title page under it
    /// (`AppleTabToolbar.scope`).
    func appleTitlePageToolbar(pageID: String, title: String, heroIsOffscreen: Bool,
                               topInset: CGFloat, usesPhoneLayout: Bool = false,
                               backIsBlocked: Bool = false, onBack: @escaping () -> Void) -> some View {
        modifier(AppleTitlePageToolbar(pageID: pageID, title: title, heroIsOffscreen: heroIsOffscreen,
                                      topInset: topInset, usesPhoneLayout: usesPhoneLayout, backIsBlocked: backIsBlocked, onBack: onBack))
    }

    /// iOS 26 sets a title page's bar buttons on round glass; iOS 18 draws bare
    /// glyphs that get lost over the art (owner, checklist row 30), so there
    /// they sit on a round material backing instead.
    @ViewBuilder
    func appleTitleBarButtonBacking(_ isActive: Bool = true) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            self
        } else if isActive {
            // A style, not modifiers on the button: iOS 18 turns a plain
            // toolbar button into a bar item and drops its background.
            self.buttonStyle(AppleRoundBarButtonStyle())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct AppleRoundBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.regularMaterial, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
#endif

private struct AppleTitlePageToolbar: ViewModifier {
    let pageID: String
    let title: String
    let heroIsOffscreen: Bool
    let topInset: CGFloat
    let usesPhoneLayout: Bool
    let backIsBlocked: Bool
    let onBack: () -> Void
    @Environment(\.appleTabToolbar) private var tabToolbar

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        standardToolbar(content)
            .modifier(ApplePhoneTitlePageChrome(isEnabled: usesPhoneLayout, title: title,
                heroIsOffscreen: heroIsOffscreen, topInset: topInset, onBack: onBack))
        #else
        standardToolbar(content)
        #endif
    }

    private func standardToolbar(_ content: Content) -> some View {
        // Read here, in `body`, so the page redraws when the tab's store
        // changes; the toolbar builder below runs outside that tracking.
        let isRefreshing = !usesPhoneLayout && (tabToolbar?.isRefreshing() ?? false)
        return content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if !usesPhoneLayout {
                    ToolbarItem(placement: .navigation) {
                        Button(action: onBack) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back")
                        .accessibilityIdentifier("detail.back")
                        .appleVisionActionTarget()
                        .appleTitleBarButtonBacking()
                    }
                    if let tabToolbar {
                        AppleTabToolbar(tab: tabToolbar.tab, isRefreshing: isRefreshing,
                                        onSearch: tabToolbar.onSearch, onRefresh: tabToolbar.onRefresh,
                                        scope: "title.\(pageID)", isTitlePage: true)
                    }
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
