import SwiftUI

/// Builds a tab's root only when SwiftUI evaluates this view's body, so the
/// root view's initialiser doesn't run for every tab when the tab view is built.
struct AppleLazyTabContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
