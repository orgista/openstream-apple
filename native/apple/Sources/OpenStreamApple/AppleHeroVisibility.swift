import SwiftUI

extension AppleHeroRotation {
    /// Whether anyone can see a hero: its scene is in front, it is on screen
    /// (not under a pushed title page or behind another tab) and, on the Mac,
    /// its window is on screen and not fully covered. A hero nobody can see
    /// holds its page and its timer, and picks up where it was when it is
    /// back — it used to go on cycling, and loading the next page's art and
    /// metadata, under the title page (N34, N36).
    public static func heroIsVisible(scenePhase: ScenePhase, isOnScreen: Bool, windowIsVisible: Bool) -> Bool {
        scenePhase == .active && isOnScreen && windowIsVisible
    }
}

extension View {
    /// Reports whether this hero can be seen (`AppleHeroRotation.heroIsVisible`)
    /// each time that changes, starting with false. Every hero carousel reads
    /// its visibility here.
    func appleHeroVisibility(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(AppleHeroVisibilityReader(onChange: onChange))
    }
}

private struct AppleHeroVisibilityReader: ViewModifier {
    let onChange: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    #if os(macOS)
    /// In a window, and that window is not fully covered (`AppleMacWindowPresence`).
    @State private var windowIsVisible = false
    #endif

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background {
                AppleMacWindowPresence { visible in
                    windowIsVisible = visible
                    report()
                }
                .accessibilityHidden(true)
            }
            #endif
            // Reported from each callback, not from an `onChange` of the
            // result: a page covered by a push may not be updated again
            // until it is back.
            .onAppear {
                isOnScreen = true
                report()
            }
            .onDisappear {
                isOnScreen = false
                report()
            }
            .onChange(of: scenePhase) { report() }
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                isOnScreen = visible
                report()
            }
    }

    private func report() {
        #if os(macOS)
        let windowIsVisible = windowIsVisible
        #else
        let windowIsVisible = true
        #endif
        onChange(AppleHeroRotation.heroIsVisible(scenePhase: scenePhase, isOnScreen: isOnScreen,
                                                 windowIsVisible: windowIsVisible))
    }
}
