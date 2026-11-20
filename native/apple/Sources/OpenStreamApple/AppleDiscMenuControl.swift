import SwiftUI

/// Returns a running DVD title to its existing navigator, preserving its resume point.
struct AppleDiscMenuControl: View {
    let coordinator: ApplePlaybackCoordinator

    var body: some View {
        Button("Disc Menu", systemImage: "opticaldisc", action: { Self.openMenu(coordinator: coordinator) })
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.disc.menu")
    }

    static func openMenu(coordinator: ApplePlaybackCoordinator) {
        guard let engine = coordinator.engine as? AetherPlaybackEngine,
              engine.discMenu.state != nil else { return }
        engine.aetherEngine.dvdMenu(.root)
    }
}
