#if os(tvOS)
import AVFoundation
import SwiftUI
import UIKit

/// Full-bleed native trailer preview for the Apple TV title page. tvOS has no
/// WebKit, so the YouTube embed the other platforms use cannot exist here; the
/// page resolves the trailer with `AppleYouTubeStreamResolver` and this layer
/// plays it with AVPlayer, filling the hero the way the backdrop does. Ends are
/// observed by the page through `AVPlayerItemDidPlayToEndTime`; the layer draws
/// no controls.
///
/// A resolved trailer arrives one of two ways. An HLS manifest plays directly.
/// Adaptive formats do not: YouTube hands back video-only and audio-only
/// streams, so they are stitched into an `AVMutableComposition` — one video
/// track and one audio track over the same time range — which AVPlayer plays
/// as a single item.
struct AppleTVTrailerPlayerView: UIViewRepresentable {
    let source: AppleYouTubeStreamResolver.Source

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.load(source: source)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.currentSource != source { uiView.load(source: source) }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
        uiView.stop()
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var player: AVPlayer?
        private var loadTask: Task<Void, Never>?
        /// `AVURLAsset` does not retain its resource-loader delegate, so the
        /// loaders have to be held here for as long as the item plays.
        private var loaders: [AppleRangedAssetLoader] = []
        #if DEBUG
        private var statusObservation: NSKeyValueObservation?
        #endif
        private(set) var currentSource: AppleYouTubeStreamResolver.Source?

        func load(source: AppleYouTubeStreamResolver.Source) {
            stop()
            currentSource = source
            backgroundColor = .black

            switch source {
            case .hls(let url):
                start(item: AVPlayerItem(url: url))
            case .adaptive(let video, let audio):
                // Building the composition needs the two moov atoms, so it is
                // a network round trip. A trailer that never resolves simply
                // never fades in; the page treats silence as no trailer.
                loadTask = Task { [weak self] in
                    var composed: (AVPlayerItem, [AppleRangedAssetLoader])
                    do {
                        composed = try await Self.composedItem(video: video, audio: audio)
                    } catch {
                        // The streams are DASH-fragmented MP4, which AVPlayer
                        // plays but `AVMutableComposition` cannot cut tracks
                        // from (`AVFoundationErrorDomain -11849`). A hero
                        // preview is better silent than absent, so the video
                        // half plays on its own rather than nothing at all.
                        let ns = error as NSError
                        appleTrace("trailer composition unavailable (\(ns.domain) \(ns.code)); playing video only")
                        guard let (asset, loader) = AppleRangedAssetLoader.asset(
                            for: video, contentType: AVFileType.mp4.rawValue
                        ) else {
                            appleTraceFailure("trailer: could not build a video-only asset either")
                            return
                        }
                        composed = (AVPlayerItem(asset: asset), [loader])
                    }
                    guard let self, !Task.isCancelled, self.currentSource == source else { return }
                    appleTrace("trailer composition ready, playing")
                    self.loaders = composed.1
                    self.start(item: composed.0)
                }
            }
        }

        private func start(item: AVPlayerItem) {
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            player.play()
            self.player = player
            #if DEBUG
            // "Playing" with a black layer means the item never became ready;
            // its own error says why.
            statusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .readyToPlay: appleTrace("trailer item ready")
                case .failed:
                    let ns = (item.error ?? NSError(domain: "none", code: 0)) as NSError
                    appleTraceFailure("trailer item failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                default: break
                }
            }
            #endif
        }

        /// One item carrying both halves of an adaptive pair, plus the loaders
        /// that must stay alive for as long as it plays.
        static func composedItem(video: URL, audio: URL) async throws -> (AVPlayerItem, [AppleRangedAssetLoader]) {
            let composition = AVMutableComposition()
            // Both halves are served by a host that refuses unranged requests,
            // so neither can be opened as a plain `AVURLAsset`.
            guard let (videoAsset, videoLoader) = AppleRangedAssetLoader.asset(for: video, contentType: AVFileType.mp4.rawValue),
                  let (audioAsset, audioLoader) = AppleRangedAssetLoader.asset(for: audio, contentType: AVFileType.mp4.rawValue) else {
                throw AppleYouTubeStreamResolver.Failure.noHLS
            }

            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDuration = videoAsset.load(.duration)
            async let audioDuration = audioAsset.load(.duration)

            guard let videoTrack = try await videoTracks.first,
                  let audioTrack = try await audioTracks.first else {
                throw AppleYouTubeStreamResolver.Failure.noHLS
            }
            // The two streams are muxed separately and their durations differ
            // by a frame or so; inserting past the shorter one throws.
            let duration = min(try await videoDuration, try await audioDuration)
            let range = CMTimeRange(start: .zero, duration: duration)

            if let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try track.insertTimeRange(range, of: videoTrack, at: .zero)
            }
            if let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try track.insertTimeRange(range, of: audioTrack, at: .zero)
            }
            return (AVPlayerItem(asset: composition), [videoLoader, audioLoader])
        }

        func stop() {
            loadTask?.cancel()
            loadTask = nil
            player?.pause()
            playerLayer.player = nil
            player = nil
            loaders = []
            currentSource = nil
        }
    }
}
#endif
