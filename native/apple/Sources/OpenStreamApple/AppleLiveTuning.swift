import SwiftUI

/// A channel that is tuning keeps quiet for its first second: the logo on
/// black, no spinner. Paramount+ shows no spinner on surf; most first frames
/// land inside a second, so a spinner there only flickers.
enum AppleLiveTuningPolicy {
    static let spinnerDelay: Duration = .seconds(1)
}

/// Shows `content` once the same tune (`id`) has lasted
/// `AppleLiveTuningPolicy.spinnerDelay`. Traced as `live spinner shown`.
struct AppleLiveTuningDelay<Content: View>: View {
    let id: String
    var immediate = false
    @ViewBuilder let content: () -> Content
    @State private var shownID: String?

    var body: some View {
        Color.clear
            .overlay { if immediate || shownID == id { content() } }
            .task(id: id) {
                do { try await Task.sleep(for: AppleLiveTuningPolicy.spinnerDelay) } catch { return }
                appleTrace("live spinner shown \(id)")
                shownID = id
            }
    }
}

/// The channel's logo on black while it tunes.
struct AppleLiveConnectingArtwork: View {
    let logoURL: URL?
    var label = "Connecting to live channel"
    var body: some View {
        ZStack {
            Color.black
            AppleLiveLogoMark(url: logoURL, height: 76, maxWidth: 132)
        }
        .accessibilityLabel(label)
    }
}
