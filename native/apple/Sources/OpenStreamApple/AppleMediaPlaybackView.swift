import AVKit
import SwiftUI
#if DEBUG && os(visionOS)
import OSLog
#endif

@MainActor
struct AppleMediaPlayerPresentation: Identifiable {
    let id = UUID()
    let request: ApplePlaybackRequest
    let fallbackCandidates: [ApplePlaybackRequest]
    let coordinator: ApplePlaybackCoordinator
    let securityScopedURL: URL?
    var sourceID: URL?
    var sourceOptionsLoader: (() async throws -> ApplePlaybackSourceOptions)?
    /// Set when the thing being played is an episode with a successor.
    var nextEpisode: AppleNextEpisodeContext?
    /// The engine this one play uses instead of `settings.playbackEngine`
    /// (the title page's OpenStream fallback after the AVPlayer-only route
    /// failed, `ApplePlaybackEngineFallback`); nil plays as usual.
    let engineOverride: ApplePlaybackEngineKind?
    /// Set by a presenter that decides what follows when every stream fails
    /// before anything plays (the title page: the OpenStream fallback, or its
    /// "Playback Unavailable" alert): the player hands the failure over and
    /// the presenter closes it. Unset, the player keeps its own alert.
    var onUnplayable: (@MainActor (ApplePlaybackUnplayable) -> Void)?

    /// Builds the player for presentation from the preferred engine in
    /// `settings`. The engine is chosen here, at presentation time, via
    /// `ApplePlaybackEngineFactory.make(preferred:)`; when the OpenStream
    /// engine cannot start and the factory falls back to the AVPlayer-only
    /// native engine, `settings.engineFellBackToNative` is set so the
    /// playback-info screen can report it.
    init(
        request: ApplePlaybackRequest,
        fallbackCandidates: [ApplePlaybackRequest] = [],
        settings: AppleSettingsStore,
        securityScopedURL: URL? = nil,
        engineOverride: ApplePlaybackEngineKind? = nil
    ) {
        self.request = request
        self.fallbackCandidates = fallbackCandidates
        self.engineOverride = engineOverride
        // The DEBUG-only Native override with not one stream the stock player
        // opens (all MKV/TS): straight to the OpenStream engine.
        let gatedEngine = ApplePlaybackEngineFallback.engine(preferred: settings.playbackEngine,
            for: [request] + fallbackCandidates)
        if engineOverride == nil, gatedEngine != settings.playbackEngine {
            appleTrace("native pre-gate: 0 of \(fallbackCandidates.count + 1) playable → openStream")
        }
        let chosenEngine = engineOverride ?? gatedEngine
        #if os(tvOS)
        // Task 9: the stock AVPlayer route whenever the container allows it —
        // unless this play was sent to the OpenStream engine on purpose.
        let preferredEngine = engineOverride
            ?? AppleTVPlaybackPresentationPolicy.engineKind(for: request, preferred: chosenEngine)
        #else
        let preferredEngine = chosenEngine
        #endif
        let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: preferredEngine)
        appleTrace("player engine \(preferredEngine) (default \(settings.playbackEngine)\(engineOverride.map { ", this play \($0)" } ?? "")) for "
            + "\(request.hints.filename.map { String($0.suffix(48)) } ?? "-"), \(fallbackCandidates.count) fallbacks")
        if fellBack {
            settings.engineFellBackToNative = true
        }
        // Apply the stored caption preference before the coordinator loads: the
        // engine reads `captionsPreference` in `load` to hand AVFoundation the
        // preferred subtitle languages and to auto-select a track on arrival.
        engine.applyCaptionPreferences(
            preference: settings.captionsPreference,
            languages: settings.subtitleLanguages,
            languagesAreExplicit: settings.hasChosenSubtitleLanguages)
        self.coordinator = ApplePlaybackCoordinator(engine: engine)
        self.securityScopedURL = securityScopedURL
    }
}

@MainActor
struct AppleMediaPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(visionOS)
    /// The window's player stage; nil only in a window that has none.
    @Environment(AppleVisionPlayerStage.self) private var visionStage: AppleVisionPlayerStage?
    @Environment(\.scenePhase) private var scenePhase
    #endif
    #if os(macOS)
    /// The window's player stage; nil only in a window that has none.
    @Environment(AppleMacPlayerStage.self) private var macStage: AppleMacPlayerStage?
    @State private var macCloseVisible = true
    @State private var macPointerActivity = 0
    private let macCommands = AppleMacCommandCenter.shared
    #endif
    #if os(visionOS)
    @State private var visionHost: ApplePlayerHost?
    #else
    @State private var host: ApplePlayerHost
    #endif
    @State private var coordinator: ApplePlaybackCoordinator
    @State private var audioSession: AppleAudioSessionCoordinator
    @State private var nativeMenuVisible = true
    @State private var nativeMenuActivity = 0
    /// Rows of the More menu on screen: the auto-hide removed the open menu
    /// after three seconds (full test 2026-09-30), so it waits while > 0.
    @State private var nativeMenuOpenItems = 0
    @State private var showsOtherSources = false
    @State private var sleepTimerMenu = false
    /// What the fallback loop walks after a failure: Automatic's order, or
    /// the picked resolution's once one is picked.
    @State private var otherSources: [ApplePlaybackSourceOption] = []
    @State private var sourceOptions: ApplePlaybackSourceOptions?
    @State private var quality = AppleStreamQualityChoice.automatic
    /// The quality switch in flight: replaced by a newer choice and cancelled
    /// when the player goes away, so a slow `prepare` can never start
    /// playback after the viewer closed it (review of f555eaa).
    @State private var qualitySwitch: Task<Void, Never>?
    /// The source on screen, so picking the quality already playing is a no-op.
    @State private var playingSource: URL?
    @State private var sourceError: String?
    @State private var isLoadingSources = false
    @State private var sourceIdentities: [URL: URL] = [:]
    @State private var triedSources = Set<URL>()
    /// Set once the engine has picked a route. From then on the route's own
    /// player owns the waiting indicator — see `showsTVLoadingSpinner`.
    @State private var hasRouted = false
    @State private var showsFallbackNotice = false
    @State private var securityAccess: AppleSecurityScopedAccess?
    /// Cues and the app subtitle menu for both engines on the stock player.
    @State private var stockSubtitles = AppleStockPlayerSubtitles()
    /// The stock player has started the next episode once already.
    @State private var stockRouteHandedOff = false
    /// Something has played in this player; a failure after that is the
    /// player's own alert, never handed to the title page.
    @State private var hasPlayed = false
    @State private var handedOffFailure = false
    #if os(tvOS)
    /// This cover was rebuilt around the player in the Picture in Picture
    /// window: the stream keeps playing, so the first load is skipped.
    @State private var resumesFromPictureInPicture: Bool
    private let presentation: AppleStremioPlayerPresentation
    #endif

    private let request: ApplePlaybackRequest
    private let fallbackCandidates: [ApplePlaybackRequest]
    private let sourceID: URL
    private let sourceOptionsLoader: (() async throws -> ApplePlaybackSourceOptions)?
    private let securityScopedURL: URL?
    private let nextEpisode: AppleNextEpisodeContext?
    private let presentationID: UUID
    private let onUnplayable: (@MainActor (ApplePlaybackUnplayable) -> Void)?

    init(presentation: AppleStremioPlayerPresentation) {
        presentationID = presentation.id
        onUnplayable = presentation.onUnplayable
        nextEpisode = presentation.nextEpisode
        sourceID = presentation.sourceID ?? presentation.request.url
        sourceOptionsLoader = presentation.sourceOptionsLoader
        request = presentation.request
        fallbackCandidates = presentation.fallbackCandidates
        securityScopedURL = presentation.securityScopedURL
        #if os(tvOS)
        self.presentation = presentation
        let parked = AppleTVPictureInPicture.shared.parked(for: presentation.coordinator)
        _resumesFromPictureInPicture = State(initialValue: parked != nil)
        let audioSession = parked?.audioSession ?? AppleAudioSessionCoordinator()
        #else
        let audioSession = AppleAudioSessionCoordinator()
        #endif
        _audioSession = State(initialValue: audioSession)
        _coordinator = State(initialValue: presentation.coordinator)
        #if os(tvOS)
        _host = State(initialValue: parked?.host ?? ApplePlayerHost(
            coordinator: presentation.coordinator,
            audioSession: audioSession
        ))
        #elseif !os(visionOS)
        _host = State(initialValue: ApplePlayerHost(
            coordinator: presentation.coordinator,
            audioSession: audioSession
        ))
        #endif
        _securityAccess = State(initialValue: nil)
    }

    var body: some View {
        playbackContent.modifier(ApplePINPresenter())
            #if os(iOS)
            .background(ApplePlayerAccessibilityModal().frame(width: 0, height: 0))
            .accessibilityAddTraits(.isModal)
            #endif
    }

    private var playbackContent: some View {
        ZStack {
            if coordinator.route == .surface {
                ApplePlaybackSurfaceView(engine: coordinator.engine)
                    .ignoresSafeArea()
            } else {
                platformPlayer
                    .ignoresSafeArea()
            }
            if drawsStockPlayerCues {
                AppleStockPlayerCueLayer(engine: coordinator.engine, subtitles: stockSubtitles,
                                         timing: coordinator.subtitleTiming)
                    .ignoresSafeArea()
            }
            if coordinator.route == .surface {
                #if os(visionOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: qualityPickerAction, onClose: closePlayer,
                    nextEpisode: nextEpisode)
                #elseif os(tvOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: qualityPickerAction, onClose: closeFromRemote,
                    nextEpisode: nextEpisode)
                #elseif os(macOS)
                // Its top bar keeps to the safe area, under the traffic lights.
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: qualityPickerAction, onClose: closePlayer,
                    nextEpisode: nextEpisode)
                #else
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: qualityPickerAction, onPlaybackMenu: { sleepTimerMenu = true }, nextEpisode: nextEpisode)
                #endif
            }
        }
        #if os(macOS)
        .overlay(alignment: .topLeading) {
            if coordinator.route == .avPlayer, macCloseVisible {
                AppleMacPlayerCloseButton(action: closePlayer)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { macPointerActivity &+= 1 }
        }
        // AVKit's floating controls hide on their own when the pointer
        // rests; the close button goes with them.
        .task(id: "\(macPointerActivity):\(coordinator.phase)") {
            withAnimation(.easeOut(duration: 0.2)) { macCloseVisible = true }
            guard case .playing = coordinator.phase else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { macCloseVisible = false }
        }
        #endif
        #if os(tvOS)
        // Task 9: black with a centred spinner and nothing else until the
        // engine reports a route. After that the stock player and the surface
        // overlay each draw their own waiting indicator.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if showsTVLoadingSpinner, request.hints.disc != nil {
                AppleDiscSpinner(size: 60)
                    .accessibilityIdentifier("player.connecting")
            } else if showsTVLoadingSpinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .controlSize(.large)
                    .accessibilityLabel("Loading stream")
                    .accessibilityIdentifier("player.connecting")
            }
        }
        .background {
            if coordinator.route == .avPlayer, let nextEpisode {
                AppleTVStockNextEpisodeAction(
                    engine: coordinator.engine, controller: host.viewController,
                    nextTitle: nextEpisode.title, isLive: request.isLive,
                    start: { _ = startNextEpisodeFromStockRoute(manual: true) })
            }
        }
        .modifier(AppleSleepTimerPresentation(coordinator: coordinator))
        .confirmationDialog("Sleep Timer", isPresented: $sleepTimerMenu) {
            AppleSleepTimerChoices(coordinator: coordinator)
        }
        .onChange(of: stockSubtitles.menuEntries) { installSourceMenu() }
        .onChange(of: stockSubtitles.moreEntries) { installSourceMenu() }
        .onChange(of: coordinator.subtitleTiming) { installSourceMenu() }
        .onChange(of: coordinator.route) { _, route in
            if route != .none {
                hasRouted = true
                #if DEBUG
                AppleLaunchClock.mark("play.route")
                #endif
            }
        }
        #endif
        #if os(iOS)
        .statusBarHidden()
        #endif
        #if os(iOS) || os(visionOS)
        .overlay(alignment: .topTrailing) {
            if coordinator.route == .avPlayer && nativeMenuVisible {
                Menu {
                    AppleSleepTimerMenu(coordinator: coordinator)
                    if sourceOptionsLoader != nil {
                        Button("Quality", systemImage: "slider.horizontal.3") { showsOtherSources = true }
                            .onAppear { nativeMenuOpenItems += 1 }
                            .onDisappear { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) }
                    }
                    if showsAppSubtitleMenu {
                        Menu("Subtitles", systemImage: "captions.bubble") {
                            ForEach(stockSubtitles.menuEntries) { entry in
                                stockSubtitleButton(entry)
                            }
                            if !stockSubtitles.moreEntries.isEmpty {
                                Menu(AppleSubtitleCueLayerPolicy.moreMenuTitle) {
                                    ForEach(stockSubtitles.moreEntries) { entry in
                                        stockSubtitleButton(entry)
                                    }
                                }
                                .onAppear { nativeMenuOpenItems += 1 }
                                .onDisappear { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) }
                                .accessibilityIdentifier("player.subtitles.more")
                            }
                            if stockSubtitles.menuEntries.contains(where: { $0.trackID != nil && $0.isSelected }) {
                                AppleSubtitleTimingMenus(
                                    timing: coordinator.subtitleTiming,
                                    change: { coordinator.subtitleTiming.apply($0) },
                                    onItemAppeared: { nativeMenuOpenItems += 1 },
                                    onItemDisappeared: { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) })
                            }
                        }
                        .onAppear { nativeMenuOpenItems += 1 }
                        .onDisappear { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) }
                        .accessibilityIdentifier("player.subtitles")
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .padding(.trailing, 16)
                .accessibilityLabel("More")
                .accessibilityIdentifier("player.more")
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            nativeMenuVisible = true
            nativeMenuActivity &+= 1
        })
        .task(id: "\(nativeMenuActivity):\(coordinator.phase):\(nativeMenuOpenItems > 0)") {
            nativeMenuVisible = true
            guard case .playing = coordinator.phase else { return }
            try? await Task.sleep(for: .seconds(nativeMenuOpenItems > 0 ? 60 : 3))
            guard !Task.isCancelled else { return }
            nativeMenuVisible = false
        }
        #endif
        #if os(visionOS)
        // AVKit's controls inside a window have no way out (the separate
        // Player window had its own close); it hides with the More button.
        // The transport overlay draws its own on the engine route.
        .overlay(alignment: .topLeading) {
            if coordinator.route == .avPlayer && nativeMenuVisible {
                AppleMacPlayerCloseButton(action: closePlayer)
                    .transition(.opacity)
            }
        }
        // The window takes the film's shape once the engine knows it.
        .onChange(of: coordinator.engine.videoSize, initial: true) { _, size in
            visionStage?.fitVideo(size, for: presentationID)
        }
        .onChange(of: scenePhase) { _, phase in
            if AppleVisionPlayerWindowPolicy.stopsPlayback(on: phase) { stopForBackground() }
        }
        #endif
        .overlay(alignment: .top) {
            if showsFallbackNotice {
                Text("Trying another source").foregroundStyle(.white).shadow(color: .black, radius: 2).padding()
            }
        }
        .sheet(isPresented: $showsOtherSources) {
            otherSourcesSheet
                #if os(visionOS)
                .frame(width: 720, height: 540)
                #elseif os(macOS)
                // A list in a Mac sheet has no height of its own; it came up
                // one row tall.
                .frame(width: 360, height: 300)
                #endif
        }
        .task(id: coordinator.fallbackNoticeGeneration) {
            guard coordinator.fallbackNoticeGeneration > 0 else { return }
            showsFallbackNotice = true
            try? await Task.sleep(for: .seconds(3))
            showsFallbackNotice = false
        }
        #if os(macOS)
        .onExitCommand { closePlayer() }
        // ␣, ⌘→ and ⌘← reach this session while it is on screen, and nothing
        // else while it is not — see `appleMacPlaybackCommands`.
        .appleMacPlaybackCommands(coordinator)
        #elseif os(tvOS)
        // Menu leaves the player on both routes (FEEDBACK Y1). The stock
        // AVPlayerViewController is a child of the cover, not the presented
        // controller, so its own Menu handling never dismisses anything, and
        // the surface overlay's handler only exists while it is on screen.
        .onExitCommand { closeFromRemote() }
        #endif
        .task {
            #if os(visionOS)
            if visionHost == nil {
                visionHost = ApplePlayerHost(coordinator: coordinator, audioSession: audioSession)
            }
            visionHost?.activate()
            visionHost?.attachRemoteCommands(request: request)
            #else
            host.activate()
            #if os(iOS) || os(macOS)
            host.enableSubtitleSelectionMirroring()
            #endif
            // The AirPods stem, Control Centre and the lock screen. Bound here
            // rather than in `init` because the Now Playing entry needs the
            // title and whether this is live.
            host.attachRemoteCommands(request: request)
            #endif
            triedSources = [sourceID]
            sourceIdentities[request.url] = sourceID
            installSourceMenu()
            coordinator.onSourceFailure = { failed in
                let identity = sourceIdentities[failed.url] ?? failed.url
                triedSources.insert(identity)
                ApplePlaybackFailureHistory.shared.record(identity)
            }
            coordinator.nextAutomaticSource = {
                try await loadOtherSources()
                // Another service's best source before more of one that is down.
                let untried = otherSources.filter {
                    !triedSources.contains($0.id) && !ApplePlaybackFailureHistory.shared.contains($0.id)
                }
                for option in coordinator.serviceHealth.healthyFirst(untried, key: \.serviceKey)
                where !triedSources.contains(option.id) {
                    triedSources.insert(option.id)
                    do {
                        let next = try await option.prepare(nil)
                        sourceIdentities[next.request.url] = option.id
                        playingSource = option.id
                        securityAccess = next.securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
                        return next.request
                    } catch is CancellationError { throw CancellationError() }
                    catch { ApplePlaybackFailureHistory.shared.record(option.id); sourceError = error.localizedDescription }
                }
                return nil
            }
            securityAccess = securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
            #if os(tvOS)
            if resumesFromPictureInPicture {
                // Back from the window: the same stream on the same host.
                resumesFromPictureInPicture = false
                hasRouted = true
                hasPlayed = true
                return
            }
            AppleTVPictureInPicture.shared.endForNewPlayback(keeping: host)
            #endif
            try? await audioSession.prepareForPlayback()
            guard !Task.isCancelled else { return }
            await coordinator.begin(request, fallbackCandidates: fallbackCandidates)
        }
        #if os(tvOS)
        .onAppear { registerPictureInPicture() }
        #endif
        .onDisappear {
            #if os(tvOS)
            // In the Picture in Picture window it plays on; the window's end
            // saves the position (`registerPictureInPicture`).
            if AppleTVPictureInPicture.shared.holds(host) { return }
            AppleTVPictureInPicture.shared.unregister(host)
            #endif
            qualitySwitch?.cancel()
            coordinator.nextAutomaticSource = nil
            coordinator.onSourceFailure = nil
            #if os(tvOS)
            saveProgressOnClose()
            #endif
            #if os(visionOS)
            visionHost?.teardown()
            #else
            host.teardown()
            #endif
            coordinator.stop()
            securityAccess = nil
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .playing = newPhase { hasPlayed = true }
            if handsFailureToPresenter, let failure = playbackFailure, let onUnplayable {
                // Every stream failed before anything played: the title page
                // closes this player and falls back to the OpenStream engine
                // or says why (`ApplePlaybackEngineFallback`).
                handedOffFailure = true
                appleTrace("player unplayable: engine=\(coordinator.engine.kind) tried=\(coordinator.triedSourceURLs.count) "
                    + "skipped=\(coordinator.streamsSkippedForEngine) kind=\(failure.kind)")
                if failure.kind == .cancelled { closePlayer(); return }
                onUnplayable(ApplePlaybackUnplayable(failure: failure, engine: coordinator.engine.kind,
                    triedSourceURLs: coordinator.triedSourceURLs))
                return
            }
            if case .ended = newPhase {
                // The transport is starting the next episode; the title page
                // swaps this player for it, so closing here would drop it.
                if coordinator.handsOffAtEnd, coordinator.route == .surface { return }
                if coordinator.route != .surface, startNextEpisodeFromStockRoute() { return }
                closePlayer()
            }
        }
        #if DEBUG && os(macOS)
        .task { await AppleDebugMacCaptionsProbe.runIfRequested(host: host, coordinator: coordinator, subtitles: stockSubtitles) }
        #endif
        #if DEBUG && os(visionOS)
        .task {
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let frames = (coordinator.engine as? AetherPlaybackEngine)?.aetherEngine.softwareHostFramesEnqueued ?? 0
                Logger(subsystem: "com.orgista.openstream", category: "vision-review")
                    .notice("route=\(String(describing: coordinator.route), privacy: .public) phase=\(String(describing: coordinator.phase), privacy: .public) position=\(coordinator.engine.position) softwareFrames=\(frames)")
            }
        }
        #endif
        .alert("Playback Failed", isPresented: playbackErrorBinding) {
            Button("Retry") { Task { await coordinator.retry() } }
            Button("Close", role: .cancel) { closePlayer() }
        } message: {
            if let failure = playbackFailure {
                Text(failure.userMessage)
            }
        }
    }

    private func closePlayer() {
        #if os(visionOS)
        // Never `dismissWindow()` here: the player is in the app's only
        // window, and that would close the app.
        if let visionStage { visionStage.dismiss(id: presentationID) } else { dismiss() }
        #elseif os(macOS)
        if let macStage { macStage.dismiss(id: presentationID) } else { dismiss() }
        #else
        dismiss()
        #endif
    }

    #if os(tvOS)
    /// `true` while the request is resolving or loading and the engine has
    /// not yet chosen a route, so neither player is on screen.
    private var showsTVLoadingSpinner: Bool {
        ApplePlaybackSpinnerPolicy.showsScreenSpinner(
            route: coordinator.route,
            isBusy: coordinator.phase.isBusy,
            hasRouted: hasRouted
        )
    }

    /// Menu on the Siri Remote: save where the owner was, then leave.
    private func closeFromRemote() {
        saveProgressOnClose()
        closePlayer()
    }

    /// How this player leaves for the Picture in Picture window (AVKit's own
    /// transport-bar button) and comes back: the root presents the same
    /// presentation again, around the same host.
    private func registerPictureInPicture() {
        let pictureInPicture = AppleTVPictureInPicture.shared
        let presentation = presentation
        let host = host
        let coordinator = coordinator
        let request = request
        pictureInPicture.register(AppleTVPictureInPicture.Owner(
            host: host, audioSession: audioSession, coordinator: coordinator, content: .onDemand,
            leave: { closePlayer() },
            restore: { pictureInPicture.restoringPresentation = presentation },
            end: {
                Self.saveProgressOnClose(coordinator: coordinator, request: request)
                host.teardown()
                coordinator.stop()
            }))
        pictureInPicture.playerAppeared(host)
    }
    #endif

    #if os(tvOS) || os(visionOS)
    /// Menu closes the player. The software route only writes progress every
    /// few seconds, so the final position is saved before the engine stops
    /// and the detail page can offer the resume point. The AVPlayer route's
    /// progress coordinator already saves when it stops observing.
    private func saveProgressOnClose() {
        Self.saveProgressOnClose(coordinator: coordinator, request: request)
    }

    private static func saveProgressOnClose(coordinator: ApplePlaybackCoordinator, request: ApplePlaybackRequest) {
        guard coordinator.route == .surface, !request.isLive else { return }
        let position = coordinator.engine.position
        let duration = coordinator.engine.duration ?? 0
        guard position.isFinite, position > 0, duration.isFinite, duration > 0 else { return }
        if let writer = coordinator.progressWriter {
            writer(position, duration)
        } else {
            ApplePlaybackStore().save(mediaID: request.mediaID, position: position, duration: duration,
                partID: request.hints.progressPartID ?? AppleDetailResume.partID(type: request.hints.addonMediaType, mediaID: request.hints.addonMediaID))
        }
    }

    #if os(visionOS)
    /// The window left the foreground (closed, the app quit, or the wearer
    /// went home): the picture is gone, so the sound goes too. Owner report:
    /// audio kept playing after the window was closed. No Picture in Picture
    /// exception: it plays on only on tvOS here.
    private func stopForBackground() {
        appleTrace("vision stage background → stop")
        saveProgressOnClose()
        visionHost?.teardown()
        coordinator.stop()
        closePlayer()
    }
    #endif
    #endif

    #if os(iOS) || os(visionOS)
    /// The app's Subtitles menu beside the stock player, only where AVKit's
    /// own captions button cannot do the job (`AppleStockSubtitleMenuPolicy`).
    private var showsAppSubtitleMenu: Bool {
        drawsStockPlayerCues && !stockSubtitles.menuEntries.isEmpty
            && AppleStockSubtitleMenuPolicy.showsAppMenu(
                tracks: coordinator.engine.subtitleTracks,
                stockPlayerListsCaptions: stockSubtitles.stockPlayerListsCaptions)
    }

    #if os(iOS) || os(visionOS)
    private func stockSubtitleButton(_ entry: AppleSubtitleCueLayerPolicy.MenuEntry) -> some View {
        Button {
            selectStockSubtitle(entry.trackID)
        } label: {
            if entry.isSelected {
                Label(entry.title, systemImage: "checkmark")
            } else {
                Text(entry.title)
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
        .onAppear { nativeMenuOpenItems += 1 }
        .onDisappear { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) }
    }
    #endif

    private func selectStockSubtitle(_ id: Int?) {
        #if os(iOS)
        // Through the host, so AVKit's CC menu and this one agree.
        host.selectSubtitleTrack(id: id)
        stockSubtitles.refresh(from: coordinator.engine)
        #else
        stockSubtitles.select(id, on: coordinator.engine)
        #endif
    }
    #endif

    /// Opens the Quality sheet; nil (no entry at all) when the source has
    /// no alternatives to offer, such as a file opened directly.
    private var qualityPickerAction: (() -> Void)? {
        sourceOptionsLoader == nil ? nil : { showsOtherSources = true }
    }

    /// Both engines publish sidecar cues and use the app's subtitle menu.
    private var drawsStockPlayerCues: Bool {
        AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(engine: coordinator.engine.kind, route: coordinator.route)
    }

    private func installSourceMenu() {
        #if os(tvOS)
        var items: [UIMenuElement] = sourceOptionsLoader == nil ? [] : [
            UIAction(title: "Quality", image: UIImage(systemName: "slider.horizontal.3")) { _ in
                showsOtherSources = true
            }]
        if drawsStockPlayerCues {
            // One captions control for embedded and add-on tracks. The app's
            // menu drives selection; AVKit draws native embedded tracks and
            // the shared cue layer draws sidecars and Aether cues.
            let entries = stockSubtitles.menuEntries
            if !entries.isEmpty {
                let engine = coordinator.engine
                let subtitles = stockSubtitles
                let coordinator = coordinator
                var children = AppleSubtitleCueLayerPolicy.uiMenuChildren(
                    entries: entries, more: subtitles.moreEntries
                ) { id in
                    subtitles.select(id, on: engine)
                }
                if entries.contains(where: { $0.trackID != nil && $0.isSelected }) {
                    // Inline, so its rows are not part of the track radio group.
                    children.append(UIMenu(title: "", options: .displayInline,
                                           children: AppleSubtitleTimingMenu.uiMenus(
                        timing: coordinator.subtitleTiming
                    ) { change in
                        coordinator.subtitleTiming.apply(change)
                    }))
                }
                items.append(UIMenu(
                    title: "Subtitles",
                    image: UIImage(systemName: "captions.bubble"),
                    options: .singleSelection,
                    children: children
                ))
            }
        }
        items.append(AppleSleepTimerMenu.uiMenu(coordinator: coordinator))
        host.viewController.transportBarCustomMenuItems = items
        #endif
    }

    private func loadOtherSources() async throws {
        guard sourceOptions == nil, let sourceOptionsLoader else { return }
        isLoadingSources = true
        defer { isLoadingSources = false }
        let options = try await sourceOptionsLoader()
        sourceOptions = options
        otherSources = options.order(for: quality)
    }

    /// Automatic and one row per resolution this device can play; the
    /// backend picks the candidate (`AppleStremioCandidateRanking.playbackOrder`).
    private var otherSourcesSheet: some View {
        NavigationStack {
            List {
                if isLoadingSources { ProgressView().tint(.white) }
                if let sourceError { Text(sourceError) }
                qualityRow(.automatic, title: "Automatic", badges: sourceOptions?.rowBadges(for: .automatic) ?? [])
                ForEach(sourceOptions?.tiers ?? [], id: \.self) { tier in
                    qualityRow(.tier(tier), title: tier.title, badges: sourceOptions?.rowBadges(for: .tier(tier)) ?? [])
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Quality")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showsOtherSources = false } }
            }
            #elseif os(iOS) || os(visionOS)
            // A way out besides swiping the sheet down (iPhone 27 v2 re-run).
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsOtherSources = false }
                        .accessibilityIdentifier("player.quality.done")
                }
            }
            #endif
            .task {
                do { try await loadOtherSources() }
                catch { sourceError = error.localizedDescription }
            }
        }
        .tint(.primary)
    }

    private func qualityRow(_ choice: AppleStreamQualityChoice, title: String,
                            badges: [AppleStreamFormatBadge] = []) -> some View {
        Button {
            qualitySwitch?.cancel()
            qualitySwitch = Task { await switchQuality(to: choice) }
        } label: {
            HStack {
                Text(title)
                if !badges.isEmpty { AppleStreamFormatBadgeInline(badges: badges) }
                Spacer()
                if quality == choice { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(quality == choice ? .isSelected : [])
        .accessibilityIdentifier("player.quality.\(title)")
    }

    /// Plays the best candidate for `choice` from where the viewer is, and
    /// makes its order the fallback for a later failure. Nothing restarts
    /// when that candidate is the one already playing.
    /// The stock player has no Next Episode card, so its end hands over the
    /// way the custom overlay's countdown does: the title page starts the
    /// next episode and swaps this player for it (tvOS stock route never
    /// advanced, iPad v2 re-run). Off when auto-play is off, unless the
    /// viewer picked the tvOS "Next Episode" action (`manual`).
    private func startNextEpisodeFromStockRoute(manual: Bool = false) -> Bool {
        let autoPlay = manual
            || UserDefaults.standard.object(forKey: AppleSettingsStore.autoPlayNextEpisodeKey) as? Bool ?? true
        guard let nextEpisode, !stockRouteHandedOff, !coordinator.isPlaceholderPlayback,
              AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: request.isLive,
                                                   isDismissed: false, isEnabled: autoPlay) else { return false }
        stockRouteHandedOff = true
        appleTrace("next episode (stock route) → \(nextEpisode.title)")
        let engine = coordinator.engine
        nextEpisode.start(AppleTrackCarryOver.capture(
            audioTracks: engine.audioTracks, activeAudioID: engine.activeAudioTrackID,
            subtitleTracks: engine.subtitleTracks, activeSubtitleID: engine.activeSubtitleTrackID))
        return true
    }

    private func switchQuality(to choice: AppleStreamQualityChoice) async {
        guard let options = sourceOptions else { return }
        let order = options.order(for: choice)
        let playing = playingSource ?? sourceID
        let position = coordinator.engine.position
        quality = choice
        otherSources = order
        showsOtherSources = false
        guard order.first?.id != playing else { return }
        triedSources = []
        for option in order where !triedSources.contains(option.id) {
            triedSources.insert(option.id)
            do {
                let next = try await option.prepare(position > 1 ? position : nil)
                guard !Task.isCancelled else { return }
                sourceIdentities[next.request.url] = option.id
                securityAccess = next.securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
                playingSource = option.id
                await coordinator.begin(next.request, fallbackCandidates: [])
                return
            } catch is CancellationError { return }
            catch { sourceError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var platformPlayer: some View {
        #if os(macOS)
        AppleMacPlayerViewRepresentable(
            playerView: host.playerView,
            zoomToFill: macCommands.zoomToFill,
            takesKeyboardFocus: true,
            subtitleEntries: stockSubtitles.menuEntries,
            moreSubtitleEntries: stockSubtitles.moreEntries,
            showsSubtitleMenu: AppleStockSubtitleMenuPolicy.showsAppMenu(
                tracks: coordinator.engine.subtitleTracks,
                stockPlayerListsCaptions: stockSubtitles.stockPlayerListsCaptions),
            onSelectSubtitle: { id in
                // Through the host, so AVKit's CC menu and this one agree.
                host.selectSubtitleTrack(id: id)
                stockSubtitles.refresh(from: coordinator.engine)
            },
            subtitleTiming: coordinator.subtitleTiming,
            onChangeSubtitleTiming: { coordinator.subtitleTiming.apply($0) },
            onOtherSources: qualityPickerAction
        )
        #elseif os(visionOS)
        if let visionHost {
            AppleMediaPlayerControllerRepresentable(viewController: visionHost.viewController)
        }
        #else
        AppleMediaPlayerControllerRepresentable(viewController: host.viewController)
        #endif
    }

    /// A failure before anything played goes to the presenter, when it takes
    /// one, instead of this player's alert.
    private var handsFailureToPresenter: Bool {
        onUnplayable != nil && !hasPlayed && !handedOffFailure
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playbackFailure != nil && !handsFailureToPresenter && !handedOffFailure },
            set: { if !$0 { coordinator.reset() } }
        )
    }

    private var playbackFailure: ApplePlaybackFailure? {
        guard case .failed(let failure) = coordinator.phase else { return nil }
        if failure.kind == .cancelled { return nil }
        return failure
    }
}

#if os(macOS) || os(visionOS)
/// The Mac and Vision Pro player's way out on the AVKit route, whose controls
/// have none: the transport overlay's close button (below the traffic lights
/// on the Mac).
private struct AppleMacPlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appleHoverAffordance()
        .padding()
        .accessibilityLabel("Close player")
        .accessibilityIdentifier("player.close")
    }
}
#endif

#if !os(macOS)
private struct AppleMediaPlayerControllerRepresentable: UIViewControllerRepresentable {
    let viewController: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController { viewController }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
#endif

#if os(tvOS)
/// Apple's "Next Episode" contextual action on the stock tvOS player, offered
/// in the same closing window as the custom overlay's card. A child view so
/// the position ticks re-render only this, not the whole player.
private struct AppleTVStockNextEpisodeAction: View {
    let engine: any ApplePlaybackEngine
    let controller: AVPlayerViewController
    let nextTitle: String
    let isLive: Bool
    let start: () -> Void

    private var isOffered: Bool {
        AppleNextEpisodePolicy.prompt(position: engine.position, duration: engine.duration,
                                      nextTitle: nextTitle, isLive: isLive) != nil
    }

    var body: some View {
        Color.clear
            .onChange(of: isOffered, initial: true) { _, offered in
                controller.contextualActions = offered
                    ? [UIAction(title: "Next Episode", image: UIImage(systemName: "forward.end.fill")) { _ in start() }]
                    : []
            }
            .onDisappear { controller.contextualActions = [] }
    }
}
#endif

typealias AppleStremioPlayerPresentation = AppleMediaPlayerPresentation

typealias AppleStremioPlayerView = AppleMediaPlayerView
