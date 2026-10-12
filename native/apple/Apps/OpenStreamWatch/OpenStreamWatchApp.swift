import SwiftUI

/// OpenStream on the wrist: a remote for whatever the phone is playing, and a
/// glance at what the Apple TV is playing.
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
    /// Moves on the refresh tick below. The resolution depends on the clock —
    /// an entry expires by getting old, which no notification announces — so
    /// the body needs something that changes to re-read it.
    @State private var tick = Date()

    var body: some View {
        NavigationStack {
            Group {
                switch link.resolved(now: tick) {
                case .nothing:
                    idle
                case .local(let title, _):
                    playing(title)
                case .remote(let deviceName, let title):
                    onOtherDevice(deviceName: deviceName, title: title)
                }
            }
            // The wordmark replaces the plain "OpenStream" title rather than
            // joining the content, so it costs no vertical space: on a 40 mm
            // face the transport row has none to give. Both states keep it.
            .navigationTitle { OpenStreamWatchWordmark() }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { link.activate() }
        .task {
            // iCloud pushes a change when the television writes one, but only
            // the clock can retire an entry that stopped arriving — a set-top
            // box that lost power leaves its last note behind. Re-reading on a
            // slow tick is what expires it.
            while !Task.isCancelled {
                link.refreshRemote()
                tick = Date()
                try? await Task.sleep(for: .seconds(15))
            }
        }
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

    /// The television's turn. No transport: the watch has no path to command an
    /// Apple TV, and three buttons that did nothing would be worse than none.
    private func onOtherDevice(deviceName: String, title: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("Playing on \(deviceName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
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

/// The app's mark and name at navigation-bar size.
///
/// The same three-bar mark the launch screen, the widgets, the iMessage app and
/// the web portal draw — restated here because the watch target does not link
/// `OpenStreamApple`, where `OpenStreamThreeBarMark` lives. Geometry matches it:
/// a full-width middle bar between two at 72%, bar height 18% and gap 12% of
/// the box, capsule ends.
///
/// Small on purpose. It sits in the navigation bar next to the system clock, so
/// it is sized against that clock rather than against a launch screen.
struct OpenStreamWatchWordmark: View {
    private let markSize = CGSize(width: 14, height: 10)

    var body: some View {
        HStack(spacing: 4) {
            mark
            Text(verbatim: "oStream")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("oStream")
        .accessibilityAddTraits(.isHeader)
    }

    private var mark: some View {
        VStack(spacing: markSize.height * 0.12) {
            bar(width: 0.72)
            bar(width: 1)
            bar(width: 0.72)
        }
        .frame(width: markSize.width, height: markSize.height)
    }

    private func bar(width: CGFloat) -> some View {
        Capsule()
            .fill(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: max(2, markSize.height * 0.18))
            .scaleEffect(x: width, y: 1)
    }
}
