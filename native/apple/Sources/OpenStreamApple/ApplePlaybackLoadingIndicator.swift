import SwiftUI

struct ApplePlaybackLoadingIndicator: View {
    var label = "Loading stream"

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.large)
            .tint(.white)
            .accessibilityLabel(Text(label))
    }
}
