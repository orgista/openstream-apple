#if os(tvOS)
import AVFoundation
import Observation

@MainActor
@Observable
final class AppleTVMultiviewTile: Identifiable {
    let channel: AppleIPTVChannel
    nonisolated let id: String
    private(set) var coordinator: ApplePlaybackCoordinator
    private(set) var routeFailure: ApplePlaybackFailure?
    private(set) var revision = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var audible = false
    @ObservationIgnored private var uncapped = false
    @ObservationIgnored private var captions = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var fullscreenPaused = false

    init(channel: AppleIPTVChannel) {
        self.channel = channel
        self.id = channel.id
        let native = AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: channel.streamURL, probedKind: channel.probedMediaKind)
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: native ? .native : .openStream)
        coordinator = ApplePlaybackCoordinator(engine: engine)
        configure(audible: false, uncapped: false, captions: false)
    }

    var failure: ApplePlaybackFailure? {
        if let routeFailure { return routeFailure }
        guard case .failed(let failure) = coordinator.phase else { return nil }
        let status = coordinator.engine.avPlayer?.currentItem?.errorLog()?.events.last?.errorStatusCode
        return ApplePlaybackFailure(kind: failure.kind, message: failure.message,
            httpStatus: status.flatMap { (400..<500).contains($0) ? $0 : failure.httpStatus } ?? failure.httpStatus,
            networkCode: failure.networkCode)
    }

    func configure(audible: Bool, uncapped: Bool, captions: Bool) {
        self.audible = audible
        self.uncapped = uncapped
        self.captions = captions
        applyRoles()
    }

    func start() {
        guard !started else { return }
        started = true
        appleTrace("multiview tile start \(id)")
        routeFailure = nil
        openTask = Task { [weak self] in
            guard let self else { return }
            guard await AppleRestrictionStore.shared.authorize(channelID: self.channel.id,
                group: self.channel.group, title: self.channel.name), !Task.isCancelled else {
                self.started = false
                return
            }
            var channel = self.channel
            // Preserve origin HTTP failures that AVPlayer can flatten into a
            // generic media error; the bounded probe closes before playback.
            do {
                let probe = try await AppleIPTVStreamProbe().validate(channel: channel)
                guard !Task.isCancelled else { return }
                channel = channel.withProbedMediaKind(probe.mediaKind)
            } catch {
                guard !Task.isCancelled else { return }
                self.recordProbeFailure(error)
                return
            }
            let native = AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: channel.streamURL, probedKind: channel.probedMediaKind)
            let kind: ApplePlaybackEngineKind = native ? .native : .openStream
            if self.coordinator.engine.kind != kind {
                self.coordinator.stop()
                let (engine, _) = ApplePlaybackEngineFactory.make(preferred: kind)
                self.coordinator = ApplePlaybackCoordinator(engine: engine)
            }
            self.applyRoles()
            self.observe()
            await self.coordinator.begin(channel.playbackRequest())
            guard !Task.isCancelled else { return }
            if case .failed = self.coordinator.phase {
                // Some providers accept the preflight but reject the actual
                // connection. AVPlayer may omit its HTTP status from errors.
                do { _ = try await AppleIPTVStreamProbe().validate(channel: channel) }
                catch {
                    guard !Task.isCancelled else { return }
                    self.recordProbeFailure(error)
                }
            }
            self.applyRoles()
            if self.fullscreenPaused { self.coordinator.engine.pause() }
            self.revision &+= 1
        }
    }

    private func recordProbeFailure(_ error: any Error) {
        if let iptv = error as? AppleIPTVError, case .streamRequestFailed(let status) = iptv {
            routeFailure = ApplePlaybackFailure(kind: .network, message: iptv.localizedDescription, httpStatus: status)
        } else {
            routeFailure = ApplePlaybackFailure.classify(error)
        }
    }

    private func observe() {
        eventTask?.cancel()
        let engine = coordinator.engine
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .tracks, .route, .phase:
                    self.applyRoles()
                    self.revision &+= 1
                default: break
                }
            }
        }
    }

    private func applyRoles() {
        let engine = coordinator.engine
        let muted = !audible || AppleTestAudioMute.isActive
        if let native = engine as? NativePlaybackEngine {
            native.multiviewMuted = muted
            native.multiviewQualityLimited = !uncapped
        }
        if let aether = engine as? AetherPlaybackEngine { aether.multiviewMuted = muted }
        engine.avPlayer?.isMuted = muted
        // Auto-selection is disabled on silent tiles before load. Once the
        // tracks arrive the audio owner alone gets the viewer's captions.
        engine.applyCaptionPreference(captions ? .always : .off)
        let languages = AppleSubtitleLanguages.storedPreferredLanguages()
        let tracks = engine.subtitleTracks
        let target: Int? = captions
            ? (tracks.first(where: { track in languages.contains { $0 == track.language } }) ?? tracks.first)?.id
            : nil
        if engine.activeSubtitleTrackID != target { engine.selectSubtitleTrack(id: target) }
    }

    func stop() {
        if started { appleTrace("multiview tile stop \(id)") }
        started = false
        openTask?.cancel(); openTask = nil
        eventTask?.cancel(); eventTask = nil
        coordinator.stop()
    }

    func setFullscreenPaused(_ paused: Bool) {
        guard fullscreenPaused != paused else { return }
        fullscreenPaused = paused
        guard started else { return }
        if paused { coordinator.engine.pause() }
        else { coordinator.engine.play() }
    }

    deinit { openTask?.cancel(); eventTask?.cancel() }
}
#endif
