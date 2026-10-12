import SwiftUI

/// Mounted on the player, never the guide. UIKit's over-full-screen iOS
/// container keeps this task alive while the same stream changes size.
struct AppleLiveWatchTracking: ViewModifier {
    let channelID: String?
    let coordinator: ApplePlaybackCoordinator
    let revision: Int
    let isLive: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: "\(channelID ?? "")|\(revision)|\(ObjectIdentifier(coordinator))") {
            await track()
        }
    }

    @MainActor private func track() async {
        guard isLive, let channelID else { return }
        var session = AppleLiveWatchSession()
        let clock = ContinuousClock()
        var previous = clock.now
        var wasPlaying = false
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let now = clock.now
            let duration = previous.duration(to: now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let playing = scenePhase == .active && coordinator.phase == .playing
                && coordinator.currentRequest?.isLive == true
            // Count only intervals bounded by playing samples. A suspended
            // process cannot turn several minutes off-screen into a watch.
            if session.advance(seconds: elapsed, playing: wasPlaying && playing && elapsed < 1) {
                AppleLiveWatchHistoryStore.shared.record(channelID, watchedSeconds: session.watchedSeconds)
                AppleInteractionTrace.record(.playback, "live watched \(channelID)")
                return
            }
            previous = now
            wasPlaying = playing
        }
    }
}
