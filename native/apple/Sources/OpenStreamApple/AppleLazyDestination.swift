import SwiftUI

/// A navigation destination built only when it is shown.
///
/// `NavigationLink { destination } label: { … }` runs its destination closure
/// as the link is made, so every card in a Discover row built a whole title
/// page — dozens of `@State`s and five stores and clients, the playback
/// preparer's file-system lookup among them — each time the row drew, only to
/// throw it away. Scrolling Discover on the Mac spent more main-thread time
/// making and destroying those pages than drawing the rows (N34 trace). This
/// holds the recipe instead and follows it when the page is pushed.
struct AppleLazyDestination<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}
