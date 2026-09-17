#if os(tvOS)
import AVFoundation
import Observation
import SwiftUI
import UIKit

/// The Live guide's channel preview: one muted stream for whatever channel has
/// held focus, rendered in the info panel where the logo sits.
///
/// It drives a `NativePlaybackEngine` rather than an `AVPlayer` of its own so
/// the channel's request headers and the loopback server are handled by the
/// same code the full player uses — several of the owner's channels do not
/// play without them.
@MainActor
@Observable
final class AppleTVChannelPreview {
    /// The channel on screen right now, or nil while nothing is previewing.
    private(set) var channelID: String?
    /// Bumped when the player changes, so the view rebinds its layer.
    private(set) var revision = 0

    /// Untracked on purpose: it is always assigned before `channelID` and
    /// `revision`, which are tracked, so the view redraws at the right moment
    /// without following every engine mutation.
    @ObservationIgnored private(set) var engine: (any ApplePlaybackEngine)?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    var player: AVPlayer? { engine?.avPlayer }

    /// Starts `channel` after the dwell, or stops when handed nil. Calling it
    /// again with the channel already previewing is a no-op, so a body pass
    /// never restarts the stream.
    func show(_ channel: AppleIPTVChannel?) {
        guard channel?.id != channelID else { return }
        startTask?.cancel()
        stopEngine()
        channelID = nil
        revision &+= 1
        guard let channel else { return }
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppleTVGuidePreviewPolicy.dwell)
            guard !Task.isCancelled, let self else { return }
            await self.start(channel)
        }
    }

    func stop() { show(nil) }

    private func start(_ channel: AppleIPTVChannel) async {
        // The preview used to hard-code `NativePlaybackEngine`, which is
        // AVPlayer only. The owner's lineup is MPEG-TS, which AVPlayer cannot
        // demux, so every preview's item failed with
        // `AVFoundationErrorDomain -11850` (operation not supported for asset)
        // and the panel kept showing the logo — measured 2026-09-15. The full
        // player never had this problem because it builds its engine through
        // the factory and lands on the libavcodec route. The preview now does
        // the same, so it can show the channels the viewer actually has.
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: .openStream)
        self.engine = engine
        var request = channel.playbackRequest()
        // A preview is a picture, not a viewing. `autoplay` used to be true,
        // which made `load` call `play()` *before* the mute below could run —
        // so every preview barked a second of live TV audio as it opened. That
        // is the tone the owner kept hearing while browsing the guide
        // (2026-09-15). Load silent, mute, then start.
        request.autoplay = false
        appleTrace("preview start \"\(channel.name)\" host=\(request.url.host() ?? "?")")
        do {
            try await engine.load(request)
        } catch {
            appleTraceFailure("preview load failed for \"\(channel.name)\": \(error.localizedDescription)")
            stopEngine()
            return
        }
        guard !Task.isCancelled, self.engine === engine else {
            appleTraceFailure("preview for \"\(channel.name)\" was superseded before it could show")
            return
        }
        appleTrace("preview loaded \"\(channel.name)\" player=\(engine.avPlayer != nil)")
        #if DEBUG
        // `load` returns as soon as the item exists, not when frames arrive,
        // so sample the player once it has had a chance to open the stream.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.engine === engine else { return }
            let player = engine.avPlayer
            let item = player?.currentItem
            let ns = item?.error as NSError?
            appleTrace(
                "preview after 5s: rate=\(player?.rate ?? -1) "
                + "timeControl=\(player?.timeControlStatus.rawValue ?? -1) "
                + "itemStatus=\(item?.status.rawValue ?? -1) "
                + "likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) "
                + "error=\(ns.map { "\($0.domain) \($0.code)" } ?? "none")"
            )
        }
        #endif
        // Silence whichever route it landed on, *then* start it: a guide that
        // browses out loud would talk over whatever the viewer is already
        // listening to.
        engine.avPlayer?.isMuted = true
        engine.avPlayer?.preventsDisplaySleepDuringVideoPlayback = false
        (engine as? AetherPlaybackEngine)?.aetherEngine.volume = 0
        engine.play()
        channelID = channel.id
        revision &+= 1
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }

    deinit { startTask?.cancel() }
}

/// The preview's picture, whichever route produced it.
///
/// AVPlayer draws through its own layer; the libavcodec route draws into the
/// engine's `AVSampleBufferDisplayLayer` surface. Most of the owner's lineup
/// is MPEG-TS and takes the second path, which is why a preview that only
/// knew about `AVPlayerLayer` never showed a picture.
struct AppleTVChannelPreviewSurface: View {
    let engine: any ApplePlaybackEngine
    let player: AVPlayer?
    let cornerRadius: CGFloat

    var body: some View {
        if engine.route == .surface {
            ApplePlaybackSurfaceView(engine: engine)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let player {
            AppleTVChannelPreviewView(player: player, cornerRadius: cornerRadius)
        }
    }
}

/// Renders the preview's player in an `AVPlayerLayer`. No controls, no
/// gestures: the panel around it owns everything the remote can do.
struct AppleTVChannelPreviewView: UIViewRepresentable {
    let player: AVPlayer?
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.apply(player: player, cornerRadius: cornerRadius)
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {
        uiView.apply(player: player, cornerRadius: cornerRadius)
    }

    static func dismantleUIView(_ uiView: PreviewLayerView, coordinator: ()) {
        uiView.apply(player: nil, cornerRadius: 0)
    }

    final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func apply(player: AVPlayer?, cornerRadius: CGFloat) {
            if playerLayer.player !== player { playerLayer.player = player }
            playerLayer.videoGravity = .resizeAspectFill
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            backgroundColor = .clear
        }
    }
}
#endif
