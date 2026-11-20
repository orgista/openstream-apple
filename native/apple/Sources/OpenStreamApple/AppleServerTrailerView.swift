import AVFoundation
import AVKit
import Observation
import SwiftUI
import VideoToolbox

/// One server trailer's player. It counts as on screen once its clock has
/// moved `AppleTrailerRevealPolicy.minimumMediaAdvance`: frames are flowing,
/// not a first buffer. A hero's (`waitsForPicture`) also waits for a frame
/// that is a picture, not black (a fade from black, a studio card on
/// black), with its letterbox band settled (`AppleTrailerPictureSettle`), so
/// the art never crossfades into a black frame or a band that then grows.
/// With `watchdog` (a hero's, which nobody pauses), one whose clock stands
/// still for `AppleTrailerArtFirstPolicy.startupTimeout`, at the start or
/// later, has failed: the still comes back and the carousel moves on rather
/// than hold a frozen frame.
///
/// A hero's is silent until it is on screen; its sound then ramps up after
/// the crossfade. One taken down while seen is held on its last frame
/// (`AppleServerTrailerHandover`) until `releaseHalted()`.
@MainActor
@Observable
final class AppleServerTrailerPlayback {
    typealias Phase = AppleServerTrailerHandover.Phase

    /// Frames measured for the picture band are this size, whatever the
    /// video's: the band is a fraction of the raster, so the squeeze does
    /// not change it, and the copy and scan stay well under a frame on the
    /// main thread, where a full 1080p or 4K BGRA copy per poll would not.
    nonisolated static let measuredFrameSize = (width: 256, height: 144)

    private(set) var handover = AppleServerTrailerHandover()
    var phase: Phase { handover.phase }
    /// The picture band inside the video's raster, as measured before the
    /// reveal; the whole raster when nothing was measured.
    private(set) var pictureWindow: ClosedRange<CGFloat> = 0...1
    /// The video's own size, once it has frames; zero before.
    private(set) var videoSize: CGSize = .zero
    private(set) var player: AVPlayer?
    /// A trailer taken down while seen, paused on its last frame.
    private var heldPlayer: AVPlayer?
    /// What the layer draws: the held frame until the next video shows.
    var shownPlayer: AVPlayer? { handover.shown == .held ? heldPlayer : player }
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var soundRamp: Task<Void, Never>?
    @ObservationIgnored private var heldSoundFade: Task<Void, Never>?
    @ObservationIgnored private var lastProgress = (media: -1.0, at: Date.distantPast)
    @ObservationIgnored private var frameOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pictureSettle = AppleTrailerPictureSettle()
    @ObservationIgnored private var isMeasuring = false

    /// `crossfade` is the stage's still ↔ video fade (0 with Reduce Motion),
    /// which the sound follows.
    func start(_ trailer: AppleServerTrailer, muted: Bool, watchdog usesWatchdog: Bool = true,
               waitsForPicture: Bool = false,
               crossfade: TimeInterval = AppleTrailerArtFirstPolicy.crossfadeDuration) {
        handover.crossfade = crossfade
        apply(handover.start())
        let item = AVPlayerItem(url: trailer.url)
        if waitsForPicture {
            let size = Self.measuredFrameSize
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])
            item.add(output)
            frameOutput = output
            pictureSettle = AppleTrailerPictureSettle()
            isMeasuring = false
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted || AppleTestAudioMute.isActive
        // Heard only once seen: the volume comes up after the crossfade.
        if waitsForPicture { player.volume = 0 }
        appleTrace("server trailer start \(muted ? "muted" : "with sound")\(AppleTestAudioMute.isActive ? " (test mute on)" : "")")
        #if !os(visionOS)
        player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        self.player = player
        pictureWindow = 0...1
        videoSize = .zero
        lastProgress = (-1, .now)
        // Every callback checks it is still this item's: a late one from a
        // replaced player must not end the new one.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.finish(.failed, for: item) }
        }
        // These deliver on the main queue, so they are on the main actor.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.advance(to: time.seconds, of: item) }
        }
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(.ended, for: item) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(.failed, for: item) }
            },
        ]
        if usesWatchdog {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if Date.now.timeIntervalSince(self.lastProgress.at) >= AppleTrailerArtFirstPolicy.startupTimeout {
                        self.finish(.failed, for: item)
                    }
                }
            }
        }
        player.play()
    }

    func setMuted(_ muted: Bool) {
        guard let player, phase == .loading || phase == .playing else { return }
        let wasSilent = player.isMuted
        player.isMuted = muted || AppleTestAudioMute.isActive
        // Unmuted while seen: the sound comes up, it does not snap on.
        if phase == .playing, wasSilent, !player.isMuted {
            player.volume = 0
            soundRamp = ramp(player, to: 1, over: AppleTrailerArtFirstPolicy.soundRampDuration)
        }
    }

    /// Takes the trailer down with a crossfade: one on screen is held on
    /// its current frame, its sound faded out, until `releaseHalted()`;
    /// anything not yet on screen simply stops.
    func conceal() {
        apply(handover.conceal())
    }

    /// Lets go of a held player once the art is back over it.
    func releaseHalted() {
        if handover.stillIsUp() { dropHeld() }
    }

    func stop() {
        detach()?.pause()
        dropHeld()
        handover.stop()
    }

    private func apply(_ takedown: AppleServerTrailerHandover.Takedown) {
        switch takedown {
        case .none:
            return
        case .discard:
            detach()?.pause()
        case let .hold(soundFade):
            guard let player = detach() else { return }
            dropHeld()
            heldPlayer = player
            if soundFade > 0, !player.isMuted, player.rate != 0, player.volume > 0 {
                heldSoundFade = ramp(player, to: 0, over: soundFade) { player.pause() }
            } else {
                player.pause()
            }
        }
    }

    /// Stops watching the running player and hands it back.
    private func detach() -> AVPlayer? {
        watchdog?.cancel()
        watchdog = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemObservers = []
        if let frameOutput { player?.currentItem?.remove(frameOutput) }
        frameOutput = nil
        soundRamp?.cancel()
        soundRamp = nil
        defer { player = nil }
        return player
    }

    private func dropHeld() {
        heldSoundFade?.cancel()
        heldSoundFade = nil
        heldPlayer?.pause()
        heldPlayer = nil
    }

    /// Moves the volume in `soundRampSteps` steps rather than cutting it.
    private func ramp(_ player: AVPlayer, to target: Float, over duration: TimeInterval, after delay: TimeInterval = 0,
                      then done: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        Task { [weak player] in
            try? await Task.sleep(for: .seconds(delay))
            let steps = AppleTrailerArtFirstPolicy.soundRampSteps
            let start = player?.volume ?? target
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard let player, !Task.isCancelled else { return }
                player.volume = start + (target - start) * Float(step) / Float(steps)
            }
            done()
        }
    }

    private func advance(to media: Double, of item: AVPlayerItem) {
        guard media.isFinite, media > lastProgress.media else { return }
        lastProgress = (media, .now)
        guard phase == .loading, media >= AppleTrailerRevealPolicy.minimumMediaAdvance else { return }
        guard let frameOutput else { return reveal(item, window: nil) }
        guard !isMeasuring else { return }
        isMeasuring = true
        // The copy and scan took 9–25 ms on the main thread on the tvOS
        // simulator even at 256 px, so they run off it. An item video
        // output's buffers may be copied from any thread.
        nonisolated(unsafe) let output = frameOutput
        let hostTime = CACurrentMediaTime()
        Task { [weak self] in
            let frame = await Self.measure(output, atHostTime: hostTime)
            self?.record(frame, for: item)
        }
    }

    private enum MeasuredFrame: Sendable {
        case noNewFrame
        /// nil: a frame that is no picture (black, a fade, a title card).
        case picture(ClosedRange<CGFloat>?)
    }

    @concurrent
    private nonisolated static func measure(_ output: AVPlayerItemVideoOutput,
                                            atHostTime hostTime: CFTimeInterval) async -> MeasuredFrame {
        appleTraceStep("server trailer measure (background)") {
            let itemTime = output.itemTime(forHostTime: hostTime)
            guard output.hasNewPixelBuffer(forItemTime: itemTime),
                  let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return .noNewFrame }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            return .picture(image.flatMap(AppleTrailerPreviewLayout.pictureWindow(in:)))
        }
    }

    private func record(_ frame: MeasuredFrame, for item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        isMeasuring = false
        guard phase == .loading, case let .picture(window) = frame else { return }
        let verdict = appleTraceStep("server trailer settle") {
            pictureSettle.record(window, size: item.presentationSize, at: .now)
        }
        guard case let .reveal(window, settled) = verdict else { return }
        appleTrace("server trailer picture \(settled ? "settled" : "unsettled") window=\(window.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil")")
        reveal(item, window: window)
    }

    private func reveal(_ item: AVPlayerItem, window: ClosedRange<CGFloat>?) {
        if let frameOutput { item.remove(frameOutput) }
        frameOutput = nil
        pictureWindow = window ?? 0...1
        videoSize = item.presentationSize
        guard let soundDelay = handover.reveal() else { return }
        dropHeld()
        if let player, player.volume < 1 {
            soundRamp = ramp(player, to: 1, over: AppleTrailerArtFirstPolicy.soundRampDuration, after: soundDelay)
        }
    }

    private func finish(_ phase: Phase, for item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        let takedown = handover.finish(phase)
        guard takedown != .none else { return }
        if phase == .failed { appleTraceFailure("server trailer failed to play") }
        apply(takedown)
    }
}

struct AppleServerTrailerStageRun: Equatable {
    let url: URL
    let plays: Bool
    let restart: UUID?
    let returnRevision: Int

    init(url: URL, plays: Bool, restart: UUID?, isPresented: Bool, sceneIsActive: Bool,
         isCovered: Bool, returnRevision: Int) {
        self.url = url
        self.plays = plays && isPresented && sceneIsActive && !isCovered
        self.restart = restart
        self.returnRevision = returnRevision
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
/// A hero's server trailer, under the Apple TV app's rules
/// (`AppleHeroTrailerGate`, art-first): muted autoplay once the still is
/// up, or with sound when Play Trailer was pressed. It reports to the
/// carousel (`AppleHomeHeroTrailerStateKey`), which holds the page while it
/// plays and moves on after it ends.
struct AppleHeroServerTrailer: View {
    let trailer: AppleServerTrailer
    let settings: AppleSettingsStore
    let art: AppleTrailerArtFirstPolicy.Art
    var artSize: CGSize? = nil
    var trailerRequest: UUID? = nil
    var onScreen: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appleHeroIsCovered) private var isCovered
    @State private var isVisible = false
    @State private var isPresented = false
    @State private var phase: AppleServerTrailerPlayback.Phase = .idle
    @State private var lastEnd: UUID?
    #if os(iOS) || os(visionOS)
    @State private var systemVideoAutoplay = UIAccessibility.isVideoAutoplayEnabled
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    #endif

    private var plays: Bool {
        #if os(iOS) || os(visionOS)
        let (systemVideoAutoplay, lowPower) = (systemVideoAutoplay, lowPower)
        #else
        let (systemVideoAutoplay, lowPower) = (true, false)
        #endif
        return AppleHeroTrailerGate.plays(.init(
            autoPlaySetting: settings.autoPlayTrailer, reduceMotion: reduceMotion, lowPower: lowPower,
            systemVideoAutoplay: systemVideoAutoplay, sceneIsActive: scenePhase == .active, halfVisible: isVisible,
            isPresented: isPresented, isCovered: isCovered, art: art, pressed: trailerRequest != nil))
    }

    var body: some View {
        ZStack {
            Color.clear
            AppleServerTrailerStage(trailer: trailer, plays: plays, muted: trailerRequest == nil,
                                    restart: trailerRequest, artSize: artSize) { phase = $0 }
        }
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            if phase == .playing { onScreen(false) }
        }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .onChange(of: phase) { old, new in
            if new == .ended { lastEnd = UUID() }
            if (old == .playing) != (new == .playing) { onScreen(new == .playing) }
        }
        .preference(key: AppleHomeHeroTrailerStateKey.self,
                    value: .init(isPlaying: phase == .loading || phase == .playing, isOnScreen: phase == .playing,
                                 isMuted: trailerRequest == nil, isRequested: trailerRequest != nil, lastEnd: lastEnd))
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
            systemVideoAutoplay = UIAccessibility.isVideoAutoplayEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        #endif
    }
}

/// A server trailer over a still, drawn on the still's own pixels
/// (`AppleServerTrailerFrame`): invisible until it plays a real picture,
/// then crossfaded in. It plays once; at the end, on a failure or when the
/// hero lets it go, the still crossfades back over its last frame. A new
/// `restart` starts it over.
struct AppleServerTrailerStage: View {
    let trailer: AppleServerTrailer
    /// The hero's gate: false takes it down.
    let plays: Bool
    var muted = true
    var restart: UUID? = nil
    /// The still's pixel size, which the video is laid out to match.
    var artSize: CGSize? = nil
    var onPhase: (AppleServerTrailerPlayback.Phase) -> Void = { _ in }
    @State private var playback = AppleServerTrailerPlayback()
    @State private var isShown = false
    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appleHeroIsCovered) private var isCovered
    @Environment(\.appleHeroReturnRevision) private var returnRevision

    private var run: AppleServerTrailerStageRun {
        AppleServerTrailerStageRun(url: trailer.url, plays: plays, restart: restart,
            isPresented: isPresented, sceneIsActive: scenePhase == .active,
            isCovered: isCovered, returnRevision: returnRevision)
    }

    var body: some View {
        AppleServerTrailerLayer(player: playback.shownPlayer, artSize: artSize, videoSize: playback.videoSize,
                                pictureWindow: playback.pictureWindow)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("hero.serverTrailer")
            .accessibilityValue(playback.phase == .playing ? "playing" : "still")
            .task(id: run) {
                guard !Task.isCancelled else { return }
                restoreStill()
                // Muted, it still takes `.ambient`: a muted player on the
                // session the last title left would stop the viewer's music.
                guard run.plays else { return }
                let audioReady = await ApplePlaybackSessionPolicy.prepareTrailerAudioAwaiting(pressed: !muted)
                guard !Task.isCancelled else { return }
                guard audioReady else {
                    playback.conceal()
                    return
                }
                playback.start(trailer, muted: muted, waitsForPicture: true,
                               crossfade: AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: reduceMotion))
            }
            .onChange(of: muted) { playback.setMuted(muted) }
            .onChange(of: playback.phase) {
                onPhase(playback.phase)
                crossfade(toVideo: playback.phase == .playing)
            }
            .onChange(of: scenePhase) { if scenePhase != .active { restoreStill() } }
            .onChange(of: isCovered) { if isCovered { restoreStill() } }
            .onAppear { isPresented = true }
            .onDisappear { isPresented = false; restoreStill() }
    }

    private func restoreStill() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isShown = false
            playback.stop()
            onPhase(.idle)
        }
    }

    private func crossfade(toVideo: Bool) {
        guard toVideo != isShown else {
            if !toVideo { playback.releaseHalted() }
            return
        }
        let duration = AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: reduceMotion)
        withAnimation(.easeInOut(duration: duration)) {
            isShown = toVideo
        } completion: {
            if !isShown { playback.releaseHalted() }
        }
    }
}

/// The trailer's picture in an `AVPlayerLayer`, laid out over the still by
/// `AppleServerTrailerFrame` and clipped to the hero.
private struct AppleServerTrailerLayer: UIViewRepresentable {
    let player: AVPlayer?
    let artSize: CGSize?
    let videoSize: CGSize
    let pictureWindow: ClosedRange<CGFloat>

    func makeUIView(context: Context) -> LayerView { LayerView() }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.geometry = .init(artSize: artSize, videoSize: videoSize, pictureWindow: pictureWindow)
    }

    final class LayerView: UIView {
        struct Geometry: Equatable {
            var artSize: CGSize?
            var videoSize: CGSize = .zero
            var pictureWindow: ClosedRange<CGFloat> = 0...1
        }

        let playerLayer = AVPlayerLayer()
        var geometry = Geometry() {
            didSet { if geometry != oldValue { setNeedsLayout() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(playerLayer)
            backgroundColor = .clear
            clipsToBounds = true
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Moved in place, never animated: the layer must not slide or
            // grow into its frame under the crossfade.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = AppleServerTrailerFrame.videoFrame(
                in: bounds.size, art: geometry.artSize,
                video: geometry.videoSize, pictureWindow: geometry.pictureWindow)
            CATransaction.commit()
        }
    }
}
#endif

/// A server trailer full screen, with sound and the system's controls:
/// what the title page's Trailer button opens. It closes itself at the end.
struct AppleServerTrailerPlayerView: View {
    let trailer: AppleServerTrailer
    let onClose: () -> Void
    @State private var playback = AppleServerTrailerPlayback()

    var body: some View {
        VideoPlayer(player: playback.shownPlayer)
            .ignoresSafeArea()
            .background(.black)
            .overlay {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(playback.phase == .playing ? "trailer.player.playing" : "trailer.player.loading")
                    .allowsHitTesting(false)
            }
            .onAppear {
                #if os(iOS) || os(tvOS) || os(visionOS)
                ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: true)
                #endif
                // The viewer may pause it: no watchdog here.
                playback.start(trailer, muted: false, watchdog: false)
            }
            .onChange(of: playback.phase) {
                if playback.phase == .ended || playback.phase == .failed { onClose() }
            }
            .onDisappear { playback.stop() }
    }
}

extension View {
    /// Plays `trailer` while `isPresented`: a full-screen cover on iPhone,
    /// iPad, Apple TV and Vision Pro; over the window on the Mac, as its
    /// player is (`AppleMacPlayerStage`), never a sheet.
    func appleServerTrailerPresentation(_ trailer: AppleServerTrailer?, isPresented: Binding<Bool>) -> some View {
        modifier(AppleServerTrailerPresenter(trailer: trailer, isPresented: isPresented))
    }
}

private struct AppleServerTrailerPresenter: ViewModifier {
    let trailer: AppleServerTrailer?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            if isPresented, let trailer {
                AppleServerTrailerPlayerView(trailer: trailer) { isPresented = false }
                    .overlay(alignment: .topLeading) {
                        Button { isPresented = false } label: {
                            AppleTitlePageMacRoundLabel(title: "Close", systemImage: "xmark")
                        }
                        .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
                        .keyboardShortcut(.cancelAction)
                        .padding(20)
                    }
                    .transition(.opacity)
            }
        }
        #else
        content.fullScreenCover(isPresented: $isPresented) {
            if let trailer {
                AppleServerTrailerPlayerView(trailer: trailer) { isPresented = false }
            }
        }
        #endif
    }
}
