import AVKit
import SwiftUI
#if DEBUG && os(visionOS)
import OSLog
#endif

@MainActor
struct AppleMediaPlayerPresentation: Identifiable {
    let id = UUID()
    var startup = ApplePlaybackStartup(starting: true)

    mutating func handOff(to startup: ApplePlaybackStartup) {
        self.startup = startup
        startup.handOff()
    }
    let request: ApplePlaybackRequest
    let fallbackCandidates: [ApplePlaybackRequest]
    let coordinator: ApplePlaybackCoordinator
    let securityScopedURL: URL?
    var sourceID: URL?
    /// The title's other playable files, walked in order after a failure.
    var sourceOptionsLoader: (() async throws -> [ApplePlaybackSourceOption])?
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
    /// Applies the stored caption preference to an engine before it loads:
    /// the one built here, and one the player adopts later (a VR file).
    let configureEngine: @MainActor (any ApplePlaybackEngine) -> Void

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
        let captions = settings.captionsPreference
        let languages = settings.subtitleLanguages
        let languagesAreExplicit = settings.hasChosenSubtitleLanguages
        configureEngine = {
            $0.applyCaptionPreferences(preference: captions, languages: languages,
                                       languagesAreExplicit: languagesAreExplicit)
        }
        configureEngine(engine)
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
    /// Set when the file is VR180/VR360 and plays through AVKit's immersive view.
    @State private var immersiveLayout: AppleImmersiveVideoLayout?
    @State private var enteredImmersive = false
    @State private var enteringImmersive = false
    @State private var immersiveEntryTask: Task<Void, Never>?
    private let configureEngine: @MainActor (any ApplePlaybackEngine) -> Void
    #else
    // StateObject keeps AVKit construction out of discarded view values.
    @StateObject private var host: ApplePlayerHost
    #endif
    @State private var coordinator: ApplePlaybackCoordinator
    #if DEBUG && os(visionOS) && targetEnvironment(simulator)
    @State private var decodedVideoFrame = "waiting"
    #endif
    #if os(visionOS)
    @State private var audioSession: AppleAudioSessionCoordinator
    #endif
    @State private var nativeMenuVisible = true
    @State private var nativeMenuActivity = 0
    /// Rows of the More menu on screen: the auto-hide removed the open menu
    /// after three seconds (full test 2026-09-30), so it waits while > 0.
    @State private var nativeMenuOpenItems = 0
    @State private var sleepTimerMenu = false
    /// What the fallback loop walks after a failure; nil until first loaded.
    @State private var otherSources: [ApplePlaybackSourceOption]?
    @State private var sourceIdentities: [URL: URL] = [:]
    @State private var triedSources = Set<URL>()
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
    private let presentation: AppleMediaPlayerPresentation
    #endif

    private let request: ApplePlaybackRequest
    private let fallbackCandidates: [ApplePlaybackRequest]
    private let sourceID: URL
    private let sourceOptionsLoader: (() async throws -> [ApplePlaybackSourceOption])?
    private let securityScopedURL: URL?
    private let nextEpisode: AppleNextEpisodeContext?
    private let presentationID: UUID
    private let startup: ApplePlaybackStartup
    private let startupRequestID: UUID?
    private let onUnplayable: (@MainActor (ApplePlaybackUnplayable) -> Void)?

    #if !os(visionOS)
    private var audioSession: AppleAudioSessionCoordinator { host.audioSession }
    #endif

    init(presentation: AppleMediaPlayerPresentation) {
        presentationID = presentation.id
        startup = presentation.startup
        startupRequestID = presentation.startup.requestID
        onUnplayable = presentation.onUnplayable
        nextEpisode = presentation.nextEpisode
        sourceID = presentation.sourceID ?? presentation.request.url
        sourceOptionsLoader = presentation.sourceOptionsLoader
        request = presentation.request
        fallbackCandidates = presentation.fallbackCandidates
        securityScopedURL = presentation.securityScopedURL
        #if os(visionOS)
        configureEngine = presentation.configureEngine
        #endif
        _coordinator = State(initialValue: presentation.coordinator)
        #if os(tvOS)
        self.presentation = presentation
        let parked = AppleTVPictureInPicture.shared.parked(for: presentation.coordinator)
        _resumesFromPictureInPicture = State(initialValue: parked != nil)
        _host = StateObject(wrappedValue: parked?.host ?? ApplePlayerHost(
            coordinator: presentation.coordinator,
            audioSession: AppleAudioSessionCoordinator()
        ))
        #elseif os(visionOS)
        _audioSession = State(initialValue: AppleAudioSessionCoordinator())
        #else
        _host = StateObject(wrappedValue: ApplePlayerHost(
            coordinator: presentation.coordinator,
            audioSession: AppleAudioSessionCoordinator()
        ))
        #endif
        _securityAccess = State(initialValue: nil)
    }

    var body: some View {
        playbackContent.modifier(ApplePINPresenter())
            #if os(iOS)
            .background(ApplePlayerAccessibilityModal().frame(width: 0, height: 0))
            // UIKit marks the presented host modal. A SwiftUI isModal trait
            // propagates into caption and scrubber nodes as synthetic alerts.
            #endif
    }

    private var discMenuIsVisible: Bool {
        (coordinator.engine as? AetherPlaybackEngine)?.discMenu.state?.isInMenu == true
    }

    private var usesTransportOverlay: Bool {
        #if os(iOS)
        coordinator.route != .none
        #else
        coordinator.route == .surface
        #endif
    }

    private var presentationRoute: ApplePlaybackPresentationRoute {
        #if os(visionOS)
        if coordinator.route == .none, coordinator.engine is NativePlaybackEngine, visionHost != nil { return .avPlayer }
        #endif
        let keepsSurface = (coordinator.engine as? AetherPlaybackEngine)?.keepsSoftwareSurfaceForAudioSwitch ?? false
        if coordinator.route == .none, keepsSurface { return .surface }
        return coordinator.route
    }

    private var playbackContent: some View {
        ZStack {
            if presentationRoute == .surface {
                ApplePlaybackSurfaceView(engine: coordinator.engine)
                    .ignoresSafeArea()
            } else if presentationRoute == .avPlayer || presentationRoute == .audioOnly {
                platformPlayer
                    .ignoresSafeArea()
            }
            if drawsStockPlayerCues, !usesTransportOverlay || discMenuIsVisible {
                AppleStockPlayerCueLayer(engine: coordinator.engine, subtitles: stockSubtitles,
                                         timing: coordinator.subtitleTiming)
                    .ignoresSafeArea()
            }
            if usesTransportOverlay, !discMenuIsVisible {
                #if os(visionOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    onClose: closePlayer,
                    nextEpisode: nextEpisode, showsWaitingIndicator: !startup.isLoading)
                #elseif os(tvOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    onClose: closeFromRemote,
                    nextEpisode: nextEpisode, showsWaitingIndicator: !startup.isLoading)
                #elseif os(macOS)
                // Its top bar keeps to the safe area, under the traffic lights.
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    onClose: closePlayer,
                    nextEpisode: nextEpisode, showsWaitingIndicator: !startup.isLoading)
                #else
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    onClose: closePlayer,
                    nextEpisode: nextEpisode, onPictureInPicture: pictureInPictureAction,
                    showsWaitingIndicator: !startup.isLoading)
                #endif
            }
            if discMenuIsVisible, let engine = coordinator.engine as? AetherPlaybackEngine {
                AppleDiscMenuOverlay(engine: engine).ignoresSafeArea()
            }
            #if DEBUG
            #if os(tvOS)
            if UserDefaults.standard.bool(forKey: "OpenStreamScrubProbe") {
                AppleTVScrubProofProbe(coordinator: coordinator, mediaID: request.mediaID,
                                       isReady: startup.hasPresentedFrame)
            }
            #endif
            #if os(visionOS) && targetEnvironment(simulator)
            if UserDefaults.standard.bool(forKey: "OpenStreamProbeVideoFrames") {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Decoded video frame")
                    .accessibilityIdentifier("player.video.frame")
                    .accessibilityValue(decodedVideoFrame)
                    .allowsHitTesting(false)
            }
            #endif
            if coordinator.route != .none, coordinator.phase == .playing || coordinator.phase == .paused {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Playback ready")
                    .accessibilityIdentifier("player.playback.ready")
                    #if os(macOS)
                    .accessibilityValue(coordinator.phase == .playing ? "Playing" : "Paused")
                    #endif
                    .allowsHitTesting(false)
            }
            if request.hints.disc != nil, !discMenuIsVisible, coordinator.phase == .playing {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Disc title")
                    .accessibilityIdentifier("player.disc.title.active")
                    .allowsHitTesting(false)
            }
            #endif
        }
        #if os(iOS) || os(tvOS)
        .onChange(of: coordinator.route) { _, route in
            guard route != .none else { return }
            #if DEBUG
            AppleLaunchClock.mark("play.route")
            #endif
        }
        #endif
        #if !os(tvOS)
        .overlay(alignment: .topTrailing) {
            if !usesTransportOverlay, coordinator.route == .avPlayer,
               (coordinator.engine as? AetherPlaybackEngine)?.discMenu.state != nil {
                AppleDiscMenuControl(coordinator: coordinator)
                    .padding(16)
                    #if os(macOS)
                    .opacity(macCloseVisible ? 1 : 0)
                    .allowsHitTesting(macCloseVisible)
                    #elseif os(iOS) || os(visionOS)
                    .padding(.trailing, 50)
                    .opacity(nativeMenuVisible ? 1 : 0)
                    .allowsHitTesting(nativeMenuVisible)
                    #endif
            }
        }
        #endif
        #if os(macOS)
        .overlay(alignment: .topLeading) {
            if coordinator.route == .avPlayer, macCloseVisible {
                ApplePlayerCloseButton(action: closePlayer)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { macPointerActivity &+= 1 }
        }
        .simultaneousGesture(TapGesture().onEnded { macPointerActivity &+= 1 })
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
        #if os(tvOS) || os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        #endif
        #if os(tvOS)
        .background {
            if coordinator.route == .avPlayer, let nextEpisode, !nextEpisode.isPartBoundary {
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
        #endif
        #if os(iOS)
        .statusBarHidden()
        #endif
        #if os(iOS) || os(visionOS)
        #if os(visionOS)
        .overlay(alignment: .topTrailing) {
            if coordinator.route == .avPlayer && nativeMenuVisible {
                Menu {
                    AppleSleepTimerMenu(coordinator: coordinator)
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
                        .font(ApplePlayerControlMetrics.chromeFont)
                        .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                        .background(.black, in: Circle())
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.top, 16)
                // AVKit's spatial chrome must stay behind the app's actions.
                .offset(z: 1)
                .accessibilityLabel("More")
                .accessibilityIdentifier("player.more")
            }
        }
        #endif
        .simultaneousGesture(TapGesture().onEnded {
            #if os(iOS)
            guard discMenuIsVisible else { return }
            #endif
            nativeMenuVisible = true
            nativeMenuActivity &+= 1
        })
        .task(id: "\(nativeMenuActivity):\(coordinator.phase):\(nativeMenuOpenItems > 0)") {
            #if os(iOS)
            guard discMenuIsVisible else { return }
            #endif
            nativeMenuVisible = true
            guard case .playing = coordinator.phase else { return }
            try? await Task.sleep(for: .seconds(nativeMenuOpenItems > 0 ? 60 : 3))
            guard !Task.isCancelled else { return }
            nativeMenuVisible = false
        }
        .onChange(of: discMenuIsVisible) { _, isMenu in
            guard isMenu else { return }
            nativeMenuVisible = true
            nativeMenuActivity &+= 1
        }
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            if discMenuIsVisible && nativeMenuVisible {
                ApplePlayerCloseButton(action: closePlayer)
            }
        }
        #endif
        #endif
        #if os(visionOS)
        // AVKit's controls inside a window have no way out (the separate
        // Player window had its own close); it hides with the More button.
        // The transport overlay draws its own on the engine route.
        .overlay(alignment: .topLeading) {
            if (presentationRoute == .avPlayer || discMenuIsVisible) && nativeMenuVisible {
                ApplePlayerCloseButton(action: closePlayer)
                    .offset(z: 1)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if immersiveLayout != nil, coordinator.route == .avPlayer, nativeMenuVisible {
                Button {
                    immersiveEntryTask?.cancel()
                    immersiveEntryTask = Task { await enterImmersive() }
                } label: {
                    Label("View in VR", systemImage: "visionpro")
                        .font(ApplePlayerControlMetrics.chromeFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: AppleDesignTokens.minimumActionSize)
                        .background(.black, in: Capsule())
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .appleHoverAffordance()
                .padding(.top, 16)
                .offset(z: 1)
                .accessibilityIdentifier("player.viewInVR")
            }
        }
        .task(id: (coordinator.engine.avPlayer?.currentItem).map(ObjectIdentifier.init)) {
            await prepareImmersive()
        }
        .task(id: "\(coordinator.route):\(coordinator.phase):\(immersiveLayout != nil)") {
            // A file that says it is VR opens in VR; one recognised only by
            // its name waits for "View in VR".
            guard let layout = immersiveLayout, !enteredImmersive,
                  coordinator.route == .avPlayer, case .playing = coordinator.phase else { return }
            #if DEBUG
            let probeRequested = AppleDebugImmersiveProbe.isRequested
            #else
            let probeRequested = false
            #endif
            guard AppleImmersiveVideoEntryPolicy.automaticallyEnters(layout, debugProbeRequested: probeRequested) else { return }
            if !layout.isFromMetadata {
                #if DEBUG
                // The probe presses "View in VR" itself, after showing it.
                nativeMenuActivity &+= 1
                appleTrace("immersive probe: flat")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                #endif
            }
            await enterImmersive()
        }
        #if DEBUG
        .task(id: enteredImmersive) {
            if enteredImmersive, AppleDebugImmersiveProbe.isRequested, let visionHost {
                await AppleDebugImmersiveProbe.run(host: visionHost, coordinator: coordinator, close: closePlayer)
            }
        }
        #endif
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
                if #available(visionOS 26.0, *), AppleImmersiveVideoDetector.isCandidate(request),
                   !(coordinator.engine is NativePlaybackEngine) {
                    let native = NativePlaybackEngine()
                    configureEngine(native)
                    coordinator.adoptEngine(native)
                }
                visionHost = ApplePlayerHost(coordinator: coordinator, audioSession: audioSession)
                #if DEBUG
                if AppleDebugImmersiveProbe.isRequested { appleTrace("immersive probe: host ready") }
                #endif
            }
            visionHost?.observeStartup(startup)
            visionHost?.activate()
            visionHost?.attachRemoteCommands(request: request)
            #else
            host.observeStartup(startup)
            host.activate()
            #if os(macOS)
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
                for option in otherSources ?? []
                where !triedSources.contains(option.id) && !ApplePlaybackFailureHistory.shared.contains(option.id) {
                    triedSources.insert(option.id)
                    do {
                        let next = try await option.prepare()
                        sourceIdentities[next.request.url] = option.id
                        securityAccess = next.securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
                        return next.request
                    } catch is CancellationError { throw CancellationError() }
                    catch { ApplePlaybackFailureHistory.shared.record(option.id) }
                }
                return nil
            }
            securityAccess = securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
            #if os(tvOS)
            if resumesFromPictureInPicture {
                // Back from the window: the same stream on the same host.
                resumesFromPictureInPicture = false
                hasPlayed = true
                return
            }
            AppleTVPictureInPicture.shared.endForNewPlayback(keeping: host)
            #endif
            try? await audioSession.prepareForPlayback()
            guard !Task.isCancelled else { return }
            await coordinator.begin(request, fallbackCandidates: fallbackCandidates)
        }
        .onAppear {
            coordinator.setOnScreen(true)
            #if os(tvOS)
            registerPictureInPicture()
            #endif
        }
        .onDisappear {
            coordinator.setOnScreen(false)
            #if os(tvOS)
            // In the Picture in Picture window it plays on; the window's end
            // saves the position (`registerPictureInPicture`).
            if AppleTVPictureInPicture.shared.holds(host) { return }
            AppleTVPictureInPicture.shared.unregister(host)
            #endif
            coordinator.nextAutomaticSource = nil
            coordinator.onSourceFailure = nil
            #if os(tvOS) || os(visionOS)
            saveProgressOnClose()
            #endif
            #if os(visionOS)
            immersiveEntryTask?.cancel()
            visionHost?.teardown()
            #else
            host.teardown()
            #endif
            coordinator.stop()
            securityAccess = nil
        }
        .onChange(of: startup.phase) { _, phase in
            guard phase == .starting, startup.requestID == startupRequestID else { return }
            #if os(visionOS)
            visionHost?.observeStartup(startup)
            #else
            host.observeStartup(startup)
            #endif
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
            refreshStartup()
            if case .ended = newPhase {
                #if os(visionOS)
                if usesTransportOverlay { return }
                #endif
                // The transport is starting the next episode; the title page
                // swaps this player for it, so closing here would drop it.
                if coordinator.handsOffAtEnd, usesTransportOverlay { return }
                if !usesTransportOverlay, startNextEpisodeFromStockRoute() { return }
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
        #if DEBUG && os(visionOS) && targetEnvironment(simulator)
        .task(id: ObjectIdentifier(coordinator.engine)) {
            decodedVideoFrame = "waiting"
            await AppleDebugVideoFrameProbe.run(engine: coordinator.engine, scene: { visionStage?.scene }) { reading in
                if decodedVideoFrame != reading { decodedVideoFrame = reading }
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

    private func refreshStartup() {
        #if os(visionOS)
        let ready = visionHost?.isReadyForDisplay == true
        #else
        let ready = host.isReadyForDisplay
        #endif
        startup.observe(coordinator.phase, route: coordinator.route, readyForDisplay: ready,
                        for: startupRequestID)
        if !startup.isAwaitingFirstFrame {
            #if os(visionOS)
            visionHost?.stopStartupObservation()
            #else
            host.stopStartupObservation()
            #endif
        }
    }

    #if os(tvOS)
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
                ApplePlaybackProgressCoordinator.saveProgressOnClose(coordinator: coordinator, request: request, hasPlayed: true)
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
        ApplePlaybackProgressCoordinator.saveProgressOnClose(coordinator: coordinator, request: request, hasPlayed: hasPlayed)
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

    #if os(visionOS)
    /// Reads the engine's asset while playback continues in the window.
    private func prepareImmersive() async {
        guard #available(visionOS 26.0, *), AppleImmersiveVideoDetector.isCandidate(request),
              let item = coordinator.engine.avPlayer?.currentItem,
              let asset = item.asset as? AVURLAsset,
              ((asset as? AppleSphericalTaggedAsset)?.sourceURL ?? asset.url) == request.url,
              let prepared = await AppleImmersiveVideoProbe.prepare(asset: item.asset,
                  filename: request.hints.filename ?? request.url.lastPathComponent),
              !Task.isCancelled, coordinator.engine.avPlayer?.currentItem === item else { return }
        if let composition = prepared.videoComposition {
            item.videoComposition = composition
            item.seekingWaitsForVideoCompositionRendering = true
        }
        immersiveLayout = prepared.layout
        visionHost?.allowImmersive()
    }

    /// AVKit offers the immersive experience once the item is ready, which
    /// can trail the first frame by a moment.
    private func enterImmersive() async {
        guard #available(visionOS 26.0, *), let visionHost, !enteringImmersive else { return }
        enteringImmersive = true
        defer { enteringImmersive = false }
        var waits = 0
        while !visionHost.supportsImmersiveExperience, waits < 20 {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            waits += 1
        }
        guard !Task.isCancelled else { return }
        let entered = await visionHost.enterImmersive()
        guard !Task.isCancelled else {
            if entered { await visionHost.leaveImmersive() }
            return
        }
        enteredImmersive = entered
        appleTrace("immersive enter \(entered ? "completed" : "refused")")
    }

    /// The app's Subtitles menu beside the stock player, only where AVKit's
    /// own captions button cannot do the job (`AppleStockSubtitleMenuPolicy`).
    private var showsAppSubtitleMenu: Bool {
        drawsStockPlayerCues && !stockSubtitles.menuEntries.isEmpty
            && AppleStockSubtitleMenuPolicy.showsAppMenu(
                tracks: coordinator.engine.subtitleTracks,
                stockPlayerListsCaptions: stockSubtitles.stockPlayerListsCaptions)
    }

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
        .accessibilityIdentifier("player.subtitle.track.\(entry.id)")
        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
        .onAppear { nativeMenuOpenItems += 1 }
        .onDisappear { nativeMenuOpenItems = max(0, nativeMenuOpenItems - 1) }
    }

    private func selectStockSubtitle(_ id: Int?) {
        stockSubtitles.select(id, on: coordinator.engine)
    }
    #endif

    #if os(iOS)
    private var pictureInPictureAction: (() -> Void)? {
        guard coordinator.route == .avPlayer, AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        return { Task { await host.startPictureInPicture() } }
    }
    #endif

    /// Both engines publish sidecar cues and use the app's subtitle menu.
    private var drawsStockPlayerCues: Bool {
        AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(engine: coordinator.engine.kind, route: coordinator.route)
    }

    private func installSourceMenu() {
        #if os(tvOS)
        var items: [UIMenuElement] = []
        if drawsStockPlayerCues {
            // One captions control for embedded and sidecar tracks. The app's
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
        if (coordinator.engine as? AetherPlaybackEngine)?.discMenu.state != nil {
            items.append(UIAction(title: "Disc Menu", image: UIImage(systemName: "opticaldisc")) { _ in
                AppleDiscMenuControl.openMenu(coordinator: coordinator)
            })
        }
        items.append(AppleSleepTimerMenu.uiMenu(coordinator: coordinator))
        host.viewController.transportBarCustomMenuItems = items
        #endif
    }

    private func loadOtherSources() async throws {
        guard otherSources == nil, let sourceOptionsLoader else { return }
        otherSources = try await sourceOptionsLoader()
    }

    /// The stock player has no Next Episode card, so its end hands over the
    /// way the custom overlay's countdown does: the title page starts the
    /// next episode and swaps this player for it (tvOS stock route never
    /// advanced, iPad v2 re-run). Off when auto-play is off, unless the
    /// viewer picked the tvOS "Next Episode" action (`manual`).
    private func startNextEpisodeFromStockRoute(manual: Bool = false) -> Bool {
        let autoPlay = manual
            || UserDefaults.standard.object(forKey: AppleSettingsStore.autoPlayNextEpisodeKey) as? Bool ?? true
        guard let nextEpisode, !stockRouteHandedOff,
              AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: request.isLive,
                                                   isDismissed: false, isEnabled: nextEpisode.isPartBoundary || autoPlay) else { return false }
        guard nextEpisode.isPartBoundary || manual || coordinator.autoPlayChain.canAdvance() else { return false }
        if !nextEpisode.isPartBoundary {
            if manual { coordinator.autoPlayChain.interacted() } else { coordinator.autoPlayChain.didAdvance() }
        }
        stockRouteHandedOff = true
        appleTrace("next episode (stock route) → \(nextEpisode.title)")
        let engine = coordinator.engine
        var carry = AppleTrackCarryOver.capture(
            audioTracks: engine.audioTracks, activeAudioID: engine.activeAudioTrackID,
            subtitleTracks: engine.subtitleTracks, activeSubtitleID: engine.activeSubtitleTrackID)
        carry.autoPlayChain = coordinator.autoPlayChain
        nextEpisode.start(carry)
        return true
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
            onChangeSubtitleTiming: { coordinator.subtitleTiming.apply($0) }
        )
        #elseif os(visionOS)
        if let visionHost {
            AppleMediaPlayerControllerRepresentable(viewController: visionHost.viewController)
        }
        #else
        AppleMediaPlayerControllerRepresentable(viewController: host.viewController)
            #if os(iOS)
            .background(ApplePlayerPictureInPictureLayer(view: host.pictureInPictureLayerView))
            #endif
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
            set: { if !$0, playbackFailure != nil { coordinator.reset() } }
        )
    }

    private var playbackFailure: ApplePlaybackFailure? {
        guard case .failed(let failure) = coordinator.phase else { return nil }
        if failure.kind == .cancelled { return nil }
        return failure
    }
}

#if os(macOS) || os(visionOS) || os(iOS)
/// Close chrome where AVKit has none or the disc menu replaces transport.
struct ApplePlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(ApplePlayerControlMetrics.chromeFont)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                #if os(visionOS)
                .background(.black, in: Circle())
                #endif
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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        #if os(iOS)
        viewController.showsPlaybackControls = false
        #endif
        return viewController
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
#endif

#if os(tvOS)
#if DEBUG
@MainActor
private struct AppleTVScrubProofProbe: View {
    let coordinator: ApplePlaybackCoordinator
    let mediaID: String
    let isReady: Bool
    @State private var reading = ""

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Scrub proof")
            .accessibilityIdentifier("player.scrub.proof")
            .accessibilityValue(reading)
            .allowsHitTesting(false)
            .task(id: isReady) {
                guard isReady else { return }
                let clock = ContinuousClock()
                var previous = clock.now
                var nextReading = previous
                var maximumGap = Duration.zero
                while !Task.isCancelled {
                    do { try await clock.sleep(for: .milliseconds(20)) }
                    catch { return }
                    let now = clock.now
                    maximumGap = max(maximumGap, previous.duration(to: now))
                    previous = now
                    guard now >= nextReading else { continue }
                    nextReading = now.advanced(by: .milliseconds(100))
                    let gap = maximumGap.components
                    let milliseconds = Double(gap.seconds) * 1_000 + Double(gap.attoseconds) / 1e15
                    let engine = coordinator.engine
                    var value = "mediaID=\(mediaID);route=\(coordinator.route);phase=\(coordinator.phase)"
                        + ";enginePhase=\(engine.phase);presentationTime=\(engine.presentationTime)"
                        + ";position=\(engine.position);duration=\(engine.duration ?? 0)"
                        + ";pending=\(coordinator.pendingSeekTarget.map(String.init(describing:)) ?? "none")"
                        + ";maxGapMs=\(milliseconds)"
                    if let player = engine.avPlayer {
                        value += ";avTime=\(player.currentTime().seconds);avRate=\(player.rate)"
                            + ";avStatus=\(player.timeControlStatus.rawValue)"
                    }
                    reading = value
                }
            }
    }
}
#endif

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
