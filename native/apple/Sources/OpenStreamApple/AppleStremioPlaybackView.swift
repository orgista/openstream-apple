import AVKit
import SwiftUI
#if DEBUG && os(visionOS)
import OSLog
#endif

@MainActor
struct AppleStremioPlayerPresentation: Identifiable {
    let id = UUID()
    let request: ApplePlaybackRequest
    let fallbackCandidates: [ApplePlaybackRequest]
    let coordinator: ApplePlaybackCoordinator
    let securityScopedURL: URL?
    var sourceID: URL?
    var sourceOptionsLoader: (() async throws -> ApplePlaybackSourceOptions)?
    /// Set when the thing being played is an episode with a successor.
    var nextEpisode: AppleNextEpisodeContext?

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
        securityScopedURL: URL? = nil
    ) {
        self.request = request
        self.fallbackCandidates = fallbackCandidates
        #if os(tvOS)
        // Task 9: the stock AVPlayer route whenever the container allows it.
        let preferredEngine = AppleTVPlaybackPresentationPolicy.engineKind(for: request, preferred: settings.playbackEngine)
        #else
        let preferredEngine = settings.playbackEngine
        #endif
        let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: preferredEngine)
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
struct AppleStremioPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(visionOS)
    @Environment(\.dismissWindow) private var dismissWindow
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
    @State private var showsOtherSources = false
    @State private var otherSources: [ApplePlaybackSourceOption] = []
    @State private var groupedSources: [ApplePlaybackSourceOption] = []
    @State private var showsAllSources = false
    @State private var sourceError: String?
    @State private var isLoadingSources = false
    @State private var sourceIdentities: [URL: URL] = [:]
    @State private var triedSources = Set<URL>()
    /// Set once the engine has picked a route. From then on the route's own
    /// player owns the waiting indicator — see `showsTVLoadingSpinner`.
    @State private var hasRouted = false
    @State private var showsFallbackNotice = false
    @State private var securityAccess: AppleSecurityScopedAccess?

    private let request: ApplePlaybackRequest
    private let fallbackCandidates: [ApplePlaybackRequest]
    private let sourceID: URL
    private let sourceOptionsLoader: (() async throws -> ApplePlaybackSourceOptions)?
    private let securityScopedURL: URL?
    private let nextEpisode: AppleNextEpisodeContext?

    init(presentation: AppleStremioPlayerPresentation) {
        nextEpisode = presentation.nextEpisode
        sourceID = presentation.sourceID ?? presentation.request.url
        sourceOptionsLoader = presentation.sourceOptionsLoader
        request = presentation.request
        fallbackCandidates = presentation.fallbackCandidates
        securityScopedURL = presentation.securityScopedURL
        let audioSession = AppleAudioSessionCoordinator()
        _audioSession = State(initialValue: audioSession)
        _coordinator = State(initialValue: presentation.coordinator)
        #if !os(visionOS)
        _host = State(initialValue: ApplePlayerHost(
            coordinator: presentation.coordinator,
            audioSession: audioSession
        ))
        #endif
        _securityAccess = State(initialValue: nil)
    }

    var body: some View {
        ZStack {
            if coordinator.route == .surface {
                ApplePlaybackSurfaceView(engine: coordinator.engine)
                    .ignoresSafeArea()
            } else {
                platformPlayer
                    .ignoresSafeArea()
            }
            if coordinator.route == .surface {
                #if os(visionOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: { showsOtherSources = true }, onClose: closePlayer,
                    nextEpisode: nextEpisode)
                #elseif os(tvOS)
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: { showsOtherSources = true }, onClose: closeFromRemote,
                    nextEpisode: nextEpisode)
                #else
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    otherSources: { showsOtherSources = true }, nextEpisode: nextEpisode)
                #endif
            }
        }
        #if os(tvOS)
        // Task 9: black with a centred spinner and nothing else until the
        // engine reports a route. After that the stock player and the surface
        // overlay each draw their own waiting indicator.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if showsTVLoadingSpinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .controlSize(.large)
                    .accessibilityLabel("Loading stream")
                    .accessibilityIdentifier("player.connecting")
            }
        }
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
        .overlay(alignment: .topTrailing) {
            if coordinator.route == .avPlayer && nativeMenuVisible {
                Menu {
                    Button("Other sources", systemImage: "list.bullet") { showsOtherSources = true }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.white).frame(width: 44, height: 44)
                }
                .padding(.trailing, 16)
                .accessibilityLabel("More")
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            nativeMenuVisible = true
            nativeMenuActivity &+= 1
        })
        .task(id: "\(nativeMenuActivity):\(coordinator.phase)") {
            nativeMenuVisible = true
            guard case .playing = coordinator.phase else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            nativeMenuVisible = false
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
            visionHost?.attachRemoteCommands(title: request.title, isLive: request.isLive)
            #else
            host.activate()
            // The AirPods stem, Control Centre and the lock screen. Bound here
            // rather than in `init` because the Now Playing entry needs the
            // title and whether this is live.
            host.attachRemoteCommands(title: request.title, isLive: request.isLive)
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
                for option in otherSources where !triedSources.contains(option.id) && !ApplePlaybackFailureHistory.shared.contains(option.id) {
                    triedSources.insert(option.id)
                    do {
                        let next = try await option.prepare()
                        sourceIdentities[next.request.url] = option.id
                        securityAccess = next.securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
                        return next.request
                    } catch is CancellationError { throw CancellationError() }
                    catch { ApplePlaybackFailureHistory.shared.record(option.id); sourceError = error.localizedDescription }
                }
                return nil
            }
            securityAccess = securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
            try? await audioSession.prepareForPlayback()
            guard !Task.isCancelled else { return }
            await coordinator.begin(request, fallbackCandidates: fallbackCandidates)
        }
        .onDisappear {
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
            if case .ended = newPhase {
                closePlayer()
            }
        }
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
                Text(failure.message)
            }
        }
    }

    private func closePlayer() {
        #if os(visionOS)
        dismissWindow(id: AppleVisionPlaybackWindow.sceneID)
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

    /// Menu closes the player. The software route only writes progress every
    /// few seconds, so the final position is saved before the engine stops
    /// and the detail page can offer the resume point. The AVPlayer route's
    /// progress coordinator already saves when it stops observing.
    private func saveProgressOnClose() {
        guard coordinator.route == .surface, !request.isLive else { return }
        let position = coordinator.engine.position
        let duration = coordinator.engine.duration ?? 0
        guard position.isFinite, position > 0, duration.isFinite, duration > 0 else { return }
        if let writer = coordinator.progressWriter {
            writer(position, duration)
        } else {
            ApplePlaybackStore().save(mediaID: request.mediaID, position: position, duration: duration,
                partID: AppleDetailResume.partID(type: request.hints.addonMediaType, mediaID: request.hints.addonMediaID))
        }
    }

    /// Menu on the Siri Remote: save where the owner was, then leave.
    private func closeFromRemote() {
        saveProgressOnClose()
        closePlayer()
    }
    #endif

    private func installSourceMenu() {
        #if os(tvOS)
        host.viewController.transportBarCustomMenuItems = [UIAction(title: "Other sources", image: UIImage(systemName: "list.bullet")) { _ in
            showsOtherSources = true
        }]
        #endif
    }

    private func loadOtherSources() async throws {
        guard otherSources.isEmpty, let sourceOptionsLoader else { return }
        isLoadingSources = true
        defer { isLoadingSources = false }
        let options = try await sourceOptionsLoader()
        otherSources = options.all
        groupedSources = options.grouped
    }

    /// The sheet's default view is the collapsed quality list; "Show all
    /// sources" swaps in the full resolver order so a specific stream stays
    /// reachable when the grouped choice isn't the one a viewer wants.
    private var visibleSources: [ApplePlaybackSourceOption] {
        showsAllSources || groupedSources.isEmpty ? otherSources : groupedSources
    }

    private var otherSourcesSheet: some View {
        NavigationStack {
            List {
                if isLoadingSources { ProgressView().tint(.white) }
                if let sourceError { Text(sourceError) }
                ForEach(visibleSources) { option in
                    Button {
                        Task {
                            do {
                                let next = try await option.prepare()
                                sourceIdentities[next.request.url] = option.id
                                securityAccess = next.securityScopedURL.map(AppleSecurityScopedAccess.init(url:))
                                triedSources = [option.id]
                                showsOtherSources = false
                                await coordinator.begin(next.request, fallbackCandidates: [])
                            } catch { sourceError = error.localizedDescription }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !isLoadingSources, groupedSources.count < otherSources.count {
                    Button(showsAllSources ? "Fewer sources" : "Show all sources") {
                        showsAllSources.toggle()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Other sources")
            .task {
                do { try await loadOtherSources() }
                catch { sourceError = error.localizedDescription }
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var platformPlayer: some View {
        #if os(macOS)
        AppleStremioMacPlayerRepresentable(playerView: host.playerView)
        #elseif os(visionOS)
        if let visionHost {
            AppleStremioPlayerControllerRepresentable(viewController: visionHost.viewController)
        }
        #else
        AppleStremioPlayerControllerRepresentable(viewController: host.viewController)
        #endif
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playbackFailure != nil },
            set: { if !$0 { coordinator.reset() } }
        )
    }

    private var playbackFailure: ApplePlaybackFailure? {
        guard case .failed(let failure) = coordinator.phase else { return nil }
        if failure.kind == .cancelled { return nil }
        return failure
    }
}

#if os(macOS)
private struct AppleStremioMacPlayerRepresentable: NSViewRepresentable {
    let playerView: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView { playerView }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
#else
private struct AppleStremioPlayerControllerRepresentable: UIViewControllerRepresentable {
    let viewController: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController { viewController }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
#endif
