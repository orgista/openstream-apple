import SwiftUI
import AetherEngine

public struct ApplePlaybackSurfaceView: View {
    private let engine: any ApplePlaybackEngine

    public init(engine: any ApplePlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        if let aether = engine as? AetherPlaybackEngine {
            let keepsSurface = aether.keepsSoftwareSurfaceForAudioSwitch
            if aether.route == .surface || keepsSurface {
                AetherPlayerSurface(engine: aether.aetherEngine)
                    .accessibilityIdentifier("player.software.surface")
            }
        }
    }
}
