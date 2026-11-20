#if os(tvOS)
import SwiftUI

struct AppleTVLiveEdgeControl: View {
    let coordinator: ApplePlaybackCoordinator
    let controlsVisible: Bool
    let focus: FocusState<AppleTVLivePlayerFocus?>.Binding
    let onReturnToLive: () -> Void
    @State private var model: AppleTransportOverlayModel?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let range = coordinator.engine.seekableRange
            let position = coordinator.engine.position
            let atEdge = coordinator.phase != .paused && AppleLiveSeekPolicy.isAtLiveEdge(position: position, in: range,
                tolerance: coordinator.liveEdgeTolerance)
            if controlsVisible || !atEdge || coordinator.phase == .paused {
                Button {
                    Task {
                        await model?.seekToLiveEdge()
                        onReturnToLive()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: atEdge ? "circle.fill" : "arrow.forward.to.line")
                        Text("LIVE")
                        if let behind = AppleLiveSystemChromePolicy.behindText(position: position,
                            range: range, tolerance: coordinator.liveEdgeTolerance) {
                            Text(behind).monospacedDigit()
                        }
                    }
                }
                .buttonStyle(AppleTVPillStyle(isSelected: !atEdge,
                    minimumSize: AppleTVGuideMetrics.standard.pillSize,
                    fontSize: AppleTVGuideMetrics.standard.badgeFontSize))
                .focused(focus, equals: .liveEdge)
                .accessibilityLabel("Live")
                .accessibilityValue(atEdge ? "At the live edge" : "Behind live")
                .accessibilityHint("Jumps to the live edge and resumes playback")
                .accessibilityIdentifier("player.live")
                .onChange(of: atEdge, initial: true) { _, atEdge in
                    guard !controlsVisible else { return }
                    if !atEdge { focus.wrappedValue = .liveEdge }
                    else if coordinator.phase != .paused, focus.wrappedValue == .liveEdge { focus.wrappedValue = .surface }
                }
            }
            #if DEBUG
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Live playback status")
                .accessibilityValue(status(position: position, range: range))
                .accessibilityIdentifier("live.player.status")
                .allowsHitTesting(false)
                .onChange(of: Int(context.date.timeIntervalSince1970 / 10)) {
                    appleTrace("live edge sample \(status(position: position, range: range))")
                }
            #endif
        }
        .task {
            model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        }
    }

    #if DEBUG
    private func status(position: Double, range: AppleSeekableRange?) -> String {
        let lag = range.map { max(0, $0.end - position) } ?? -1
        return "phase=\(coordinator.phase) position=\(position) lag=\(lag) tolerance=\(coordinator.liveEdgeTolerance)"
    }
    #endif
}
#endif
