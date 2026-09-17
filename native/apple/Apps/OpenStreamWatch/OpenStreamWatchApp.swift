import SwiftUI

/// OpenStream on the wrist: a remote for whatever the phone or Apple TV is
/// playing.
///
/// Deliberately not a second browsing app. A watch screen is a glance and a
/// tap, and the thing worth having there is transport control plus what is
/// playing — not a catalogue.
@main
struct OpenStreamWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchNowPlayingView()
        }
    }
}

struct WatchNowPlayingView: View {
    @State private var link = AppleWatchLink.shared

    var body: some View {
        NavigationStack {
            Group {
                if let title = link.nowPlayingTitle {
                    playing(title)
                } else {
                    idle
                }
            }
            .navigationTitle("OpenStream")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { link.activate() }
    }

    /// Title, then the transport. No artwork: a watch face is small enough that
    /// a poster costs the controls their room.
    private func playing(_ title: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 14) {
                button("gobackward.10", "Back 10 seconds") { link.send(.skipBackward) }
                button(link.isPlaying ? "pause.fill" : "play.fill",
                       link.isPlaying ? "Pause" : "Play") { link.send(.togglePlayPause) }
                button("goforward.10", "Forward 10 seconds") { link.send(.skipForward) }
            }
        }
        .padding(.horizontal, 4)
    }

    /// One line, no glyph, no instructions.
    ///
    /// `play.slash` was here and, at watch size, the slash crossing the
    /// triangle's apex reads as a mouse cursor — verified by zooming a capture
    /// 4x (2026-09-16). A symbol that has to be squinted at is worse than no
    /// symbol, and the app's empty states are a title and nothing else anyway.
    private var idle: some View {
        Text("Nothing Playing")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}
