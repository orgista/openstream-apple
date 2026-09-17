import SwiftUI
import AetherEngine

/// SwiftUI surface for an `ApplePlaybackEngine`. On the OpenStream engine, the engine's own `AetherPlayerSurface` is mounted when the route is
/// `.surface` (libavcodec software decode into `AVSampleBufferDisplayLayer`);
/// on every other route and on the native fallback engine the view is empty,
/// because the native video path is drawn by `AVPlayerLayer` elsewhere.
public struct ApplePlaybackSurfaceView: View {
    private let engine: any ApplePlaybackEngine

    public init(engine: any ApplePlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        if let aether = engine as? AetherPlaybackEngine, aether.route == .surface {
            AetherPlayerSurface(engine: aether.aetherEngine)
        } else {
            EmptyView()
        }
    }
}
