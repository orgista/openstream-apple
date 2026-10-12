import Foundation

/// The channel and programme named above the full-screen scrubber.
struct AppleLiveNowPlaying: Equatable, Sendable {
    var logoURL: URL?
    var text: String
}

/// Pure rules for the system-style Live chrome.
@MainActor
enum AppleLiveSystemChromePolicy {
    /// Live chrome stays up four seconds after the last touch, as the system
    /// player's does.
    static let autoHideSeconds: Double = 4

    /// ±15 s skips only with a rewind window longer than 30 s.
    static func showsSkips(dvrSpan: Double) -> Bool { dvrSpan > 30 }

    /// "−0:42" while behind the live edge; nothing at it.
    static func behindText(position: Double, range: AppleSeekableRange?, tolerance: Double) -> String? {
        guard let range, AppleLiveSeekPolicy.offersDVR(range), position.isFinite else { return nil }
        let behind = range.end - min(range.end, max(range.start, position))
        guard behind > tolerance else { return nil }
        return "−" + AppleTransportOverlayModel.timeText(behind)
    }

    /// Channel swipes start only in the middle 60 % of the height, so the
    /// home-indicator swipe and the scrubber are never read as a zap.
    static func acceptsZapSwipe(startY: Double, height: Double) -> Bool {
        guard height > 0 else { return false }
        let fraction = startY / height
        return fraction >= 0.2 && fraction <= 0.8
    }
}

#if os(iOS)
import AVKit
import SwiftUI

/// The full-screen Live player's chrome on iPhone and iPad, laid out as the
/// system player (`AVPlayerViewController`, iOS 16+) lays out its own: close
/// and Picture in Picture top-left, More top-right, the scrubber at the
/// bottom with LIVE as its left label, AirPlay / captions / channel list
/// under it on the right, channel up/down on the trailing edge.
///
/// Owner items 12–15 (2026-10-09): the stroked close ring, the "Channels" and
/// "Last Channel" text buttons and the thumbed slider read as cheap. Last
/// Channel is the first row of More; the list is a glyph.
@MainActor
struct AppleLiveSystemChrome: View {
    typealias NowPlaying = AppleLiveNowPlaying

    let model: AppleTransportOverlayModel
    let coordinator: ApplePlaybackCoordinator
    let request: ApplePlaybackRequest
    let isMuted: Bool
    let onToggleMute: (() -> Void)?
    let nowPlaying: NowPlaying?
    let onClose: () -> Void
    let onPictureInPicture: (() -> Void)?
    let onLastChannel: (() -> Void)?
    let onStartOver: (() -> Void)?
    let onShowChannels: (() -> Void)?
    let onChannelStep: ((AppleLiveZappingPolicy.Direction) -> Void)?
    let sharePlayMenu: AppleTransportOverlay.SharePlayMenu?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                if !model.showsWaitingIndicator, !isFailed { centreTransport }
                Spacer(minLength: 0)
                bottomBlock
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let onChannelStep {
                chevrons(onChannelStep)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    // MARK: - Top

    private var topRow: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                glyph("xmark", size: 17)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("player.close")
            if let onPictureInPicture {
                Button(action: onPictureInPicture) {
                    glyph("pip.enter", size: 17)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Picture in Picture")
                .accessibilityIdentifier("player.pip")
            }
            Spacer(minLength: 0)
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if let onLastChannel {
                Button("Last Channel", systemImage: "arrow.uturn.backward", action: onLastChannel)
                    .appleLiveMenuPresence(model)
                    .accessibilityIdentifier("live.player.lastChannel")
            }
            if let onStartOver {
                Button("Start Over", systemImage: "backward.end", action: onStartOver)
                    .appleLiveMenuPresence(model)
                    .accessibilityIdentifier("live.player.startOver")
            }
            AppleSleepTimerMenu(coordinator: coordinator, isLive: request.isLive, transport: model)
            if let sharePlayMenu {
                Button(sharePlayMenu.primaryTitle, systemImage: "shareplay", action: sharePlayMenu.primaryAction)
                    .appleLiveMenuPresence(model)
                if let title = sharePlayMenu.secondaryTitle, let action = sharePlayMenu.secondaryAction {
                    Button(title, role: .destructive, action: action)
                }
            }
        } label: {
            glyph("ellipsis", size: 20)
        }
        .appleBareMenu()
        .accessibilityLabel("More")
        .accessibilityIdentifier("player.options")
    }

    // MARK: - Centre

    private var showsSkips: Bool {
        guard let range = model.liveSeekableRange else { return false }
        return AppleLiveSystemChromePolicy.showsSkips(dvrSpan: range.span)
    }

    private var centreTransport: some View {
        HStack(spacing: 48) {
            if showsSkips {
                skip(-15, "gobackward.15", label: "Back 15 seconds", id: "player.skip-back")
            }
            Button { model.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .appleTransportGlyphLegibility()
                    .frame(width: 72, height: 72)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.play-pause")
            if showsSkips {
                skip(15, "goforward.15", label: "Forward 15 seconds", id: "player.skip-forward")
                    .disabled(model.isAtLiveEdge)
                    .opacity(model.isAtLiveEdge ? 0.4 : 1)
            }
        }
    }

    private func skip(_ seconds: Double, _ symbol: String, label: String, id: String) -> some View {
        Button { Task { await model.skip(by: seconds) } } label: {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .appleTransportGlyphLegibility()
                .frame(width: 56, height: 56)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func chevrons(_ step: @escaping (AppleLiveZappingPolicy.Direction) -> Void) -> some View {
        VStack(spacing: 0) {
            Button { model.bumpActivity(); step(.next) } label: {
                chevron("chevron.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next Channel")
            .accessibilityIdentifier("live.player.next")
            Button { model.bumpActivity(); step(.previous) } label: {
                chevron("chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous Channel")
            .accessibilityIdentifier("live.player.previous")
        }
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.white.opacity(0.8))
            .appleTransportGlyphLegibility()
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }

    // MARK: - Bottom

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let nowPlaying {
                AppleLiveNowPlayingLine(nowPlaying: nowPlaying)
            }
            AppleLiveScrubberRow(model: model)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if isMuted, let onToggleMute {
                    Button(action: onToggleMute) {
                        glyph("speaker.slash.fill", size: 17)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unmute")
                    .accessibilityIdentifier("player.mute")
                }
                if model.showsAirPlay {
                    AppleRoutePicker()
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("player.airplay")
                }
                AppleTransportTrackMenu(
                    audioTracks: model.audioTracks,
                    selectedAudioID: model.selectedAudioID,
                    subtitleTracks: model.subtitleTracks,
                    preferredSubtitleLanguages: model.preferredSubtitleLanguages,
                    selectedSubtitleID: model.selectedSubtitleID,
                    onSelectAudio: { model.selectAudio($0) },
                    onSelectSubtitle: { model.selectSubtitle($0) },
                    subtitleTiming: model.subtitleTiming,
                    onChangeSubtitleTiming: { model.changeSubtitleTiming($0) },
                    onMenuItemAppeared: { model.menuItemAppeared() },
                    onMenuItemDisappeared: { model.menuItemDisappeared() }
                )
                if let onShowChannels {
                    Button {
                        model.bumpActivity()
                        onShowChannels()
                    } label: {
                        glyph("list.bullet", size: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Channels")
                    .accessibilityIdentifier("player.channels")
                }
            }
        }
    }

    private func glyph(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .appleTransportGlyphLegibility()
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }

    private var isFailed: Bool {
        if case .failed = coordinator.phase { return true }
        return false
    }

    private var isPlaying: Bool {
        if case .playing = coordinator.phase { return true }
        return false
    }
}

/// "[logo] ESPN · NFL Live" above the scrubber.
private struct AppleLiveNowPlayingLine: View {
    let nowPlaying: AppleLiveSystemChrome.NowPlaying

    var body: some View {
        HStack(spacing: 8) {
            if nowPlaying.logoURL != nil {
                AppleLiveLogoMark(url: nowPlaying.logoURL, height: 20, maxWidth: 32)
            }
            Text(nowPlaying.text)
                .font(.subheadline)
                .lineLimit(1)
                .appleTransportGlyphLegibility()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.player.nowPlaying")
    }
}

/// LIVE as the scrubber's left label, the thin bar, and "−0:42" on the right
/// only while behind. Without a rewind window the row is the label alone.
@MainActor
private struct AppleLiveScrubberRow: View {
    let model: AppleTransportOverlayModel
    @State private var dragFraction: Double?

    var body: some View {
        HStack(spacing: 10) {
            liveLabel
            if model.isScrubbable {
                bar
                if let behind = AppleLiveSystemChromePolicy.behindText(position: model.position,
                    range: model.liveSeekableRange, tolerance: AppleTransportOverlayModel.liveEdgeTolerance) {
                    Text(behind)
                        .font(.caption.monospacedDigit())
                        .appleTransportGlyphLegibility()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var liveLabel: some View {
        let atEdge = model.isAtLiveEdge || !model.isScrubbable
        let label = HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(atEdge ? Color.red : Color.gray)
            Text("LIVE")
                .font(.caption.bold())
                .foregroundStyle(atEdge ? Color.white : Color.white.opacity(0.6))
        }
        .appleTransportGlyphLegibility()
        if model.isScrubbable, !model.isAtLiveEdge {
            Button { Task { await model.seekToLiveEdge() } } label: {
                label.frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Live")
            .accessibilityValue("Behind live")
            .accessibilityHint("Jumps to the live edge")
            .accessibilityIdentifier("player.live")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live")
                .accessibilityIdentifier("player.live")
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let fraction = dragFraction ?? model.progress
            let dragging = dragFraction != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: max(0, proxy.size.width * fraction))
                if dragging {
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: proxy.size.width * fraction - 6)
                }
            }
            .frame(height: dragging ? 6 : 3)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.bumpActivity()
                    dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                }
                .onEnded { _ in
                    let target = dragFraction ?? model.progress
                    dragFraction = nil
                    Task { await model.scrub(to: target) }
                })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(model.isAtLiveEdge ? "Live" : "Behind live")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: Task { await model.skip(by: 15) }
            case .decrement: Task { await model.skip(by: -15) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player.scrubber")
    }
}

/// The system AirPlay picker, white on the video.
private struct AppleRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private extension View {
    func appleLiveMenuPresence(_ model: AppleTransportOverlayModel) -> some View {
        onAppear { model.menuItemAppeared() }
            .onDisappear { model.menuItemDisappeared() }
    }
}
#endif
