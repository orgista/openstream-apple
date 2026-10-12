#if os(tvOS)
import SwiftUI

struct AppleTVMultiviewTileView: View {
    let tile: AppleTVMultiviewTile
    let isAudio: Bool
    let onSelect: () -> Void
    let onBack: () -> Void
    let onChange: () -> Void
    let onPromote: () -> Void
    let onRemove: () -> Void
    let isFocused: Bool
    @State private var subtitles = AppleStockPlayerSubtitles()

    var body: some View {
        let _ = tile.revision
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    Color.black
                    if let player = tile.coordinator.engine.avPlayer {
                        AppleTVMultiviewVideoView(player: player, onBack: onBack)
                    } else {
                        ApplePlaybackSurfaceView(engine: tile.coordinator.engine)
                    }
                    if isAudio {
                        AppleStockPlayerCueLayer(engine: tile.coordinator.engine, subtitles: subtitles)
                    }
                    if let failure = tile.failure {
                        Text(AppleMultiviewPolicy.message(for: failure))
                            .font(.headline).multilineTextAlignment(.center).padding(24)
                    } else if reconnecting {
                        VStack(spacing: 12) { ProgressView(); Text("Reconnecting…").font(.headline) }
                    } else if tile.coordinator.phase.isBusy || tile.coordinator.phase == .idle {
                        ProgressView().accessibilityLabel("Connecting to \(tile.channel.name)")
                    }
                }
                .clipped()
                HStack(spacing: 12) {
                    Text(tile.channel.name).font(.headline).lineLimit(1)
                    if isAudio { Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true) }
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
            }
            .padding(6)
            .contentShape(.rect)
            .overlay { Rectangle().strokeBorder(isFocused ? Color.white : Color.clear, lineWidth: 3) }
        }
        .buttonStyle(AppleTVBareButtonStyle())
        .onExitCommand(perform: onBack)
        .onKeyPress(.escape) { onBack(); return .handled }
        .contextMenu {
            Button("Change Channel", action: onChange)
            Button("Make Big", action: onPromote)
            Button("Remove", role: .destructive, action: onRemove)
        }
        .accessibilityLabel(tile.channel.name)
        .accessibilityValue(tile.failure.map(AppleMultiviewPolicy.message) ?? (reconnecting ? "Reconnecting" : (isAudio ? "Audio playing" : "Muted")))
        .accessibilityIdentifier("multiview.tile.\(tile.id)")
    }

    private var reconnecting: Bool {
        if tile.coordinator.isReconnectingLive { return true }
        switch tile.coordinator.engine.phase {
        case .stalled, .rebuffering: return true
        default: return false
        }
    }
}
#endif
