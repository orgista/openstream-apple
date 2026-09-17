import AVKit
import SwiftUI
#if !os(macOS)
import UIKit
#endif

@MainActor
final class AppleReloadGate {
    private(set) var isRunning = false

    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func end() { isRunning = false }
}

@MainActor
struct AppleLiveTVView: View {
    @State private var channels: [AppleIPTVChannel] = []
    @State private var channelGroups: [AppleIPTVChannelGroup] = []
    @State private var channelSnapshot = AppleLiveChannelSnapshot(channels: [], channelIDs: [], categories: ["All", "Favorites"])
    @State private var channelsRevision = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var selectedCategory = "All"
    @State private var selectedChannel: AppleIPTVChannel?
    @State private var playbackRevision = 0
    @AppStorage("openstream.live.lastChannelID") private var lastWatchedChannelID = ""
    @State private var guideStore = AppleIPTVGuideStore()
    @State private var premierGuide: [AppleChannelLineupEntry] = []
    @State private var lineupIndex = AppleChannelLineupIndex([])
    @State private var playbackCoordinator = ApplePlaybackCoordinator()
    @State private var configuredEngine: ApplePlaybackEngineKind?
    @FocusState private var focusedChannelID: String?
    @State private var reloadGate = AppleReloadGate()
    @State private var sharePlay = AppleSharePlaySessionStore.shared
    @State private var sharedChannelChoices: [AppleIPTVChannel] = []
    @State private var showsSharedChannelChoices = false
    #if os(tvOS)
    @State private var tvPlayer: AppleTVLivePlayerPresentation?
    @State private var tvFocusRestore = 0
    /// Owned here, not by the player screen: switching to a channel that
    /// needs the other engine rebuilds the screen, and the footer must stay
    /// open across that rebuild.
    // The channel strip only appears on a remote swipe, which no headless tool
    // can send, so it could never be checked in a capture. This opens it at
    // launch for review builds.
    #if DEBUG
    @State private var tvFooter = AppleTVLiveFooterState(
        phase: UserDefaults.standard.bool(forKey: "OpenStreamLiveFooterVisible") ? .shown : .hidden
    )
    #else
    @State private var tvFooter = AppleTVLiveFooterState()
    #endif
    #endif

    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void

    private let client = AppleIPTVClient()

    var body: some View {
        @Bindable var settings = settings

        Group {
            if isLoading, channels.isEmpty {
                ProgressView()
            } else if channels.isEmpty {
                AppleSourceEmptyState(
                    title: errorMessage ?? "No Live Channels",
                    actionTitle: "Open Settings",
                    action: openSettings
                )
            } else {
                #if os(tvOS)
                tvGuide
                #else
                VStack(spacing: 0) {
                    if let selectedChannel {
                        AppleLiveInlinePlayer(
                            request: selectedChannel.playbackRequest(),
                            coordinator: playbackCoordinator,
                            playbackRevision: playbackRevision,
                            logoURL: selectedChannel.logoURL,
                            sharedChannel: try? AppleSharePlayChannel(channel: selectedChannel),
                            sharePlay: sharePlay,
                            liveChannel: selectedChannel
                        )
                        .id(ObjectIdentifier(playbackCoordinator))
                        .livePinnedPlayerLayout()
                        .accessibilityLabel("Live player for \(selectedChannel.name)")
                    } else {
                        lastWatchedCard
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppleDesignTokens.spacingLarge) {
                            ForEach(channelSnapshot.categories, id: \.self) { category in
                                Button(category) { selectedCategory = category }
                                    .font(AppleDesignTokens.fontSubheadline)
                                    .foregroundStyle(selectedCategory == category ? AppleDesignTokens.textPrimary : AppleDesignTokens.textSecondary)
                                    .padding(.vertical, 10)
                                    .overlay(alignment: .bottom) {
                                        Capsule().fill(AppleDesignTokens.brandAccent)
                                            .frame(height: 2)
                                            .opacity(selectedCategory == category ? 1 : 0)
                                    }
                            }
                        }
                        .padding(.horizontal, AppleDesignTokens.spacingMedium)
                    }
                    .scrollIndicators(.hidden)

                    // One line, only when the cap kept channels off the guide.
                    // Not an explainer: the count is the whole message, and the
                    // way to narrow it is the package picker the viewer already
                    // has. Silent truncation was the thing to avoid.
                    if channelSnapshot.hiddenCount > 0 {
                        Text("Showing \(channelSnapshot.channels.count) of \(channelSnapshot.channels.count + channelSnapshot.hiddenCount) channels")
                            .font(AppleDesignTokens.fontCaption)
                            .foregroundStyle(AppleDesignTokens.textSecondary)
                            .padding(.horizontal, AppleDesignTokens.spacingMedium)
                            .accessibilityIdentifier("live.cap.notice")
                    }

                    AppleIPTVGuideGridView(
                        channels: channelSnapshot.channels,
                        guide: guideStore.guide(for: channelSnapshot.channelIDs),
                        entries: premierGuide,
                        favoriteIDs: settings.favoriteChannelIDs,
                        onSelect: play,
                        onToggleFavorite: toggleFavorite,
                        onVisibleChannels: refreshGuide
                    )
                    .safeAreaPadding(.bottom, 8)
                }
                #endif
            }
        }
        .modifier(AppleLiveSearchModifier(isEnabled: !channels.isEmpty, query: $query))
        .task(id: settings.playbackEngine) {
            guard configuredEngine != settings.playbackEngine else { return }
            configuredEngine = settings.playbackEngine
            playbackCoordinator.stop()
            let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: settings.playbackEngine)
            settings.engineFellBackToNative = fellBack
            engine.applyCaptionPreferences(
            preference: settings.captionsPreference,
            languages: settings.subtitleLanguages,
            languagesAreExplicit: settings.hasChosenSubtitleLanguages)
            playbackCoordinator = ApplePlaybackCoordinator(engine: engine)
        }
        .onChange(of: settings.captionsPreference) { _, preference in
            playbackCoordinator.engine.applyCaptionPreference(preference)
        }
        .task(id: reloadIdentity) { await reload() }
        .task(id: projectionIdentity) {
            await rebuildChannelGroups()
        }
        .task(id: "shareplay:\(sharePlay.revision):\(channelsRevision)") {
            resolveSharedChannel()
        }
        .confirmationDialog("Choose the source for this channel", isPresented: $showsSharedChannelChoices, titleVisibility: .visible) {
            ForEach(sharedChannelChoices) { channel in
                Button(sourceStore.sources.first(where: { $0.id == channel.sourceID })?.name ?? channel.name) {
                    startChannel(channel, shareSelection: false)
                }
            }
            Button("Leave SharePlay", role: .cancel) { sharePlay.leave() }
        }
        .alert("SharePlay", isPresented: Binding(
            get: { sharePlay.message != nil },
            set: { if !$0 { sharePlay.message = nil } }
        )) {
            Button("OK") { sharePlay.message = nil }
            if sharePlay.isActive {
                Button("Open Settings") { sharePlay.message = nil; openSettings() }
                Button("Leave SharePlay", role: .destructive) { sharePlay.message = nil; sharePlay.leave() }
            }
        } message: { Text(sharePlay.message ?? "") }
        // The full-screen player owns the failure alert (Retry/Close). A second
        // alert here, bound to the same coordinator phase, collided with the
        // fullScreenCover and dismissed the player silently (2026-09-03).
    }

    private var reloadIdentity: String {
        ApplePlaybackIdentity.digest(for: sourceStore.sources
            .filter { $0.kind == .liveTV }
            .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)" }
            .joined(separator: "\u{1f}"))
    }

    private var projectionIdentity: String {
        ApplePlaybackIdentity.digest(for: [
            String(channelsRevision),
            selectedCategory,
            query,
            settings.liveChannelScope.rawValue,
            settings.regionalZIPCode,
            String(settings.showPayPerViewChannels),
            String(settings.show24x7Channels),
            settings.liveChannelPackage.rawValue,
            settings.customChannelPackage.identity,
            settings.favoriteChannelIDs.sorted().joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}"))
    }

    private func reload() async {
        guard reloadGate.begin() else { return }
        defer { reloadGate.end() }
        premierGuide = (try? AppleChannelLineupPresets.premierUS()) ?? []
        lineupIndex = AppleChannelLineupIndex(premierGuide)
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        await AppleIPTVChannelCache.shared.retain(Set(sources.map(\.id)))
        guard !sources.isEmpty else {
            channels = []
            channelGroups = []
            channelsRevision &+= 1
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }

        // Show the saved lineup first. Re-fetching all 9376 of the owner's
        // channels took 2137 ms before the guide could draw anything
        // (2026-09-15); a lineup changes rarely, so the saved copy goes up at
        // once and the network answer replaces it underneath.
        if channels.isEmpty {
            var cached: [AppleIPTVChannel] = []
            for source in sources {
                if let snapshot = await AppleIPTVChannelCache.shared.snapshot(for: source.id) {
                    cached.append(contentsOf: snapshot.channels)
                }
            }
            if !cached.isEmpty, !Task.isCancelled {
                channels = cached
                channelsRevision &+= 1
                #if DEBUG
                AppleLaunchClock.mark("live.cached(\(cached.count))")
                #endif
            }
        }

        var loaded: [AppleIPTVChannel] = []
        var errors: [String] = []
        for source in sources {
            do {
                let sourceChannels = try await client.channels(
                    source: source,
                    credentials: try sourceStore.iptvCredentials(for: source)
                )
                loaded.append(contentsOf: sourceChannels)
                await AppleIPTVChannelCache.shared.store(sourceChannels, for: source.id)
                sourceStore.recordValidationSuccess(
                    id: source.id,
                    summary: "Connected · \(sourceChannels.count) channels",
                    discoveredItemCount: sourceChannels.count,
                    capabilities: ["Live channels", "Playback"]
                )
                try? await mediaIndex.replace(
                    instanceID: source.id,
                    with: AppleMediaIngestion.channelRecords(source: source, channels: sourceChannels)
                )
            } catch is CancellationError {
                return
            } catch {
                sourceStore.recordValidationFailure(id: source.id, summary: error.localizedDescription)
                errors.append("\(source.name): \(error.localizedDescription)")
            }
        }
        channels = loaded
        channelsRevision &+= 1
        #if DEBUG
        AppleLaunchClock.mark("live.channels(\(loaded.count))")
        #endif
        errorMessage = errors.first
        if selectedChannel == nil, !sharePlay.isActive, let channel = lastWatchedChannel ?? channels.first {
            // On Apple TV this only fills the Now Playing strip; playback
            // starts from the guide, never on its own.
            startChannel(channel, shareSelection: false, present: false)
            #if os(tvOS) && DEBUG
            // Headless capture hook: `defaults write com.orgista.openstream
            // OpenStreamLiveAutoPlay -bool YES` opens the full-screen player
            // on the strip's channel as soon as the guide has loaded.
            if UserDefaults.standard.bool(forKey: "OpenStreamLiveAutoPlay") {
                // `OpenStreamLiveAutoPlayChannel` names the channel to open, so
                // a known-dead one can be opened on purpose; otherwise the
                // strip's channel.
                let wanted = UserDefaults.standard.string(forKey: "OpenStreamLiveAutoPlayChannel")
                let channel = wanted.flatMap { name in
                    channels.first { $0.name.localizedCaseInsensitiveContains(name) }
                } ?? channel
                print("[OpenStream] debug auto-play \(channel.name)")
                startChannel(channel, shareSelection: false)
                // `OpenStreamLiveAutoSwitchCount` then flips to the following
                // channels on a timer. The Siri Remote cannot be driven
                // headlessly, and channel switching is where the player
                // misbehaves, so this is the only way to capture that path.
                let hops = UserDefaults.standard.integer(forKey: "OpenStreamLiveAutoSwitchCount")
                if hops > 0 { scheduleDebugChannelHops(count: hops, from: channel) }
            }
            #endif
        }
    }

    #if os(tvOS) && DEBUG
    /// Simulator only: walk to the next channels every few seconds so the
    /// switch path can be captured. Never reachable without the default set.
    private func scheduleDebugChannelHops(count: Int, from channel: AppleIPTVChannel) {
        let list = channels
        guard let start = list.firstIndex(where: { $0.id == channel.id }), list.count > 1 else { return }
        let gap = UserDefaults.standard.object(forKey: "OpenStreamLiveAutoSwitchSeconds") as? Double ?? 8
        Task { @MainActor in
            for hop in 1 ... count {
                try? await Task.sleep(for: .seconds(max(0.2, gap)))
                let next = list[(start + hop) % list.count]
                print("[OpenStream] debug channel hop \(hop) -> \(next.name)")
                startChannel(next, shareSelection: false)
            }
        }
    }
    #endif

    /// The slice of the channel strip worth fetching EPG for: the channel being
    /// watched and its neighbours either side. Bounded, because the lineup can
    /// be thousands long and the strip only ever shows a handful at a time.
    private func stripGuideChannelIDs(around channel: AppleIPTVChannel, radius: Int = 20) -> [String] {
        let all = channelSnapshot.channels
        guard let index = all.firstIndex(where: { $0.id == channel.id }) else {
            return all.prefix(2 * radius).map(\.id)
        }
        let lower = max(all.startIndex, index - radius)
        let upper = min(all.endIndex, index + radius)
        return all[lower ..< upper].map(\.id)
    }

    private func refreshGuide(_ visibleIDs: Set<String>) async {
        guard !visibleIDs.isEmpty else { return }
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        guideStore.retainSources(Set(sources.map(\.id)))
        for source in sources {
            if source.iptvType == .xtream {
                guard let credentials = try? sourceStore.iptvCredentials(for: source) else { continue }
                guideStore.configure(xtreamBase: source.url, username: credentials.username, password: credentials.password, sourceID: source.id)
            } else {
                let sourceChannels = channels.filter { $0.sourceID == source.id }
                let mapping = sourceChannels.reduce(into: [String: String]()) { result, channel in
                    if let id = channel.guideID { result[channel.id] = id }
                }
                guideStore.configure(xmltvURL: sourceChannels.first?.guideURL, sourceID: source.id, channelMapping: mapping)
            }
        }
        await guideStore.refreshVisible(channelIDs: visibleIDs)
    }

    private func rebuildChannelGroups() async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        let updated = await AppleChannelProjection.buildGroupsOffMain(
            from: channels,
            scope: settings.liveChannelScope,
            showPayPerView: settings.showPayPerViewChannels,
            favoriteIDs: settings.favoriteChannelIDs,
            query: clean,
            regionalZIPCode: settings.regionalZIPCode,
            show24x7: settings.liveChannelPackage == .custom || settings.show24x7Channels
        )
        guard !Task.isCancelled else { return }
        #if DEBUG
        AppleLaunchClock.mark("live.groups(\(updated.count))")
        #endif
        let package = settings.liveChannelPackage
        let custom = settings.customChannelPackage
        let entries = premierGuide
        let favorites = settings.favoriteChannelIDs
        let category = selectedCategory
        let snapshot = await Task.detached(priority: .userInitiated) {
            AppleLiveChannelSnapshot.build(groups: updated, package: package, custom: custom,
                entries: entries, favoriteIDs: favorites, category: category)
        }.value
        guard !Task.isCancelled else { return }
        #if DEBUG
        print("[OpenStream] live lineup source=\(channels.count) package=\(package.rawValue) guide=\(snapshot.channels.count) categories=\(snapshot.categories.count)")
        AppleLaunchClock.mark("live.snapshot(\(snapshot.channels.count))")
        #endif
        channelGroups = updated
        channelSnapshot = snapshot
        let availableIDs = Set(snapshot.channelIDs)
        if focusedChannelID == nil || !availableIDs.contains(focusedChannelID ?? "") {
            focusedChannelID = updated.first?.channels.first?.id
        }
    }

    private func play(_ channel: AppleIPTVChannel) {
        startChannel(channel, shareSelection: true)
    }

    private func startChannel(_ channel: AppleIPTVChannel, shareSelection: Bool, present: Bool = true) {
        if shareSelection { sharePlay.selected(channel) }
        #if os(tvOS)
        if present { ensureTVEngine(for: channel.playbackRequest()) }
        #endif
        playbackCoordinator.sharePlayChannel = try? AppleSharePlayChannel(channel: channel)
        playbackRevision &+= 1
        selectedChannel = channel
        lastWatchedChannelID = channel.id
        #if os(tvOS)
        if present, tvPlayer == nil {
            // A fresh player starts with the footer hidden: Menu shows it.
            #if DEBUG
            tvFooter = AppleTVLiveFooterState(
                phase: UserDefaults.standard.bool(forKey: "OpenStreamLiveFooterVisible") ? .shown : .hidden
            )
            #else
            tvFooter = AppleTVLiveFooterState()
            #endif
            tvPlayer = AppleTVLivePlayerPresentation()
        }
        #endif
    }

    #if os(tvOS)
    /// Guide as the tab root; playback is a full-screen cover with the stock
    /// player. The cover's identity is fixed so switching channels from the
    /// footer updates the player in place, and closing it hands focus back to
    /// the rail cell of the channel that was playing. SwiftUI clears
    /// `tvPlayer` itself when the cover is dismissed.
    private var tvGuide: some View {
        AppleTVLiveGuideScreen(
            channels: channelSnapshot.channels,
            categories: channelSnapshot.categories,
            hiddenCount: channelSnapshot.hiddenCount,
            selectedCategory: $selectedCategory,
            guide: guideStore.guide(for: channelSnapshot.channelIDs),
            guideRevision: guideStore.revision,
            entries: premierGuide,
            favoriteIDs: settings.favoriteChannelIDs,
            nowPlaying: selectedChannel ?? lastWatchedChannel ?? channels.first,
            hasActiveSearch: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            previewsEnabled: settings.autoPlayTrailer,
            isPlayerOpen: tvPlayer != nil,
            focusRestoreToken: tvFocusRestore,
            focusRestoreChannelID: lastWatchedChannelID,
            searchDestination: { AppleTVChannelSearchEditor(query: $query) },
            onSelect: play,
            onToggleFavorite: toggleFavorite,
            onVisibleChannels: refreshGuide
        )
        // The tab root draws no page title on a television; the tab bar names it.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $tvPlayer, onDismiss: { tvFocusRestore &+= 1 }) { _ in
            if let channel = selectedChannel {
                AppleTVLivePlayerScreen(
                    channel: channel,
                    coordinator: playbackCoordinator,
                    footerChannels: channelSnapshot.channels,
                    footer: $tvFooter,
                    alternateLineup: channels,
                    guide: guideStore.guide(for: channelSnapshot.channelIDs),
                    onSwitch: { startChannel($0, shareSelection: true) }
                )
                .id(ObjectIdentifier(playbackCoordinator))
                // The guide only fetches EPG for rows visible in the grid, so
                // a viewer who opened a channel without scrolling the guide had
                // no programme data for the strip's channels and the "what is
                // playing" line stayed blank. Ask for the ones the strip can
                // actually reach, around the channel being watched.
                .task(id: channel.id) {
                    await refreshGuide(Set(stripGuideChannelIDs(around: channel)))
                }
            }
        }
    }

    /// Task 9: the stock AVPlayer route whenever the container allows it. The
    /// engine is rebuilt only when the policy's answer differs from the one
    /// the coordinator already holds.
    private func ensureTVEngine(for request: ApplePlaybackRequest) {
        let kind = AppleTVPlaybackPresentationPolicy.engineKind(for: request, preferred: settings.playbackEngine)
        guard playbackCoordinator.engine.kind != kind else { return }
        playbackCoordinator.stop()
        let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: kind)
        if kind == .openStream { settings.engineFellBackToNative = fellBack }
        engine.applyCaptionPreferences(
            preference: settings.captionsPreference,
            languages: settings.subtitleLanguages,
            languagesAreExplicit: settings.hasChosenSubtitleLanguages)
        playbackCoordinator = ApplePlaybackCoordinator(engine: engine)
    }
    #endif

    private func resolveSharedChannel() {
        guard let shared = sharePlay.channel, !channels.isEmpty else { return }
        let choices = shared.candidates(in: channels)
        if let selectedChannel, choices.contains(where: { $0.id == selectedChannel.id }) {
            playbackCoordinator.sharePlayChannel = shared
            sharePlay.refreshPlayback(playbackCoordinator, channel: shared)
        } else if choices.count == 1, let channel = choices.first {
            startChannel(channel, shareSelection: false)
        } else if choices.isEmpty {
            sharePlay.message = "Your TV sources do not have \(shared.title)."
        } else {
            sharedChannelChoices = choices
            showsSharedChannelChoices = true
        }
    }

    private var lastWatchedCard: some View {
        AppleLiveConnectingArtwork(logoURL: lastWatchedChannel?.logoURL ?? channels.first?.logoURL)
            .livePinnedPlayerLayout()
    }

    private var lastWatchedChannel: AppleIPTVChannel? {
        guard !lastWatchedChannelID.isEmpty else { return nil }
        return channels.first { $0.id == lastWatchedChannelID }
    }

    private func toggleFavorite(_ id: String) {
        settings.favoriteChannelIDs = AppleTVGuideRailCellModel.togglingFavorite(id, in: settings.favoriteChannelIDs)
    }

}

private struct AppleLiveConnectingArtwork: View {
    let logoURL: URL?
    var body: some View {
        ZStack {
            Color.black
            AsyncImage(url: logoURL) { image in
                image.resizable().scaledToFit()
            } placeholder: { Color.clear }
            .frame(width: 132, height: 76)
        }
        .accessibilityLabel("Connecting to live channel")
    }
}

private struct LivePinnedPlayerLayout: ViewModifier {
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscapePad = isPad && verticalSizeClass == .compact
        if isLandscapePad {
            content
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, count: 100, span: 42, spacing: 0)
        } else {
            content
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isPad ? 16 : 0)
                .ignoresSafeArea(.container, edges: .horizontal)
        }
        #else
        content
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
        #endif
    }
}

private extension View {
    func livePinnedPlayerLayout() -> some View { modifier(LivePinnedPlayerLayout()) }
}

/// Inline Live-tab playback surface. The coordinator and AVKit host stay owned
/// by the tab so channel changes reload the same engine without presenting a
/// second player. AVKit owns transport controls and its full-screen affordance.
@MainActor
struct AppleLiveInlinePlayer: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var host: ApplePlayerHost
    @State private var audioSession: AppleAudioSessionCoordinator
    @State private var suspendedRequestID: String?
    @State private var suspendedPosition: Double?
    @State private var suspendedWasPlaying: Bool?
    @State private var showsSurfaceFullScreen = false
    @State private var lifetime = AppleLivePlaybackLifetime()

    let request: ApplePlaybackRequest
    let coordinator: ApplePlaybackCoordinator
    let playbackRevision: Int
    let logoURL: URL?
    let sharedChannel: AppleSharePlayChannel?
    let sharePlay: AppleSharePlaySessionStore
    let liveChannel: AppleIPTVChannel?

    init(request: ApplePlaybackRequest, coordinator: ApplePlaybackCoordinator, playbackRevision: Int, logoURL: URL?, sharedChannel: AppleSharePlayChannel?, sharePlay: AppleSharePlaySessionStore = .shared, liveChannel: AppleIPTVChannel? = nil) {
        self.request = request
        self.coordinator = coordinator
        self.playbackRevision = playbackRevision
        self.logoURL = logoURL
        self.sharedChannel = sharedChannel
        self.sharePlay = sharePlay
        self.liveChannel = liveChannel
        let audioSession = AppleAudioSessionCoordinator()
        _audioSession = State(initialValue: audioSession)
        _host = State(initialValue: ApplePlayerHost(
            coordinator: coordinator,
            audioSession: audioSession
        ))
    }

    var body: some View {
        ZStack {
            if coordinator.route == .surface {
                if !showsSurfaceFullScreen {
                    ApplePlaybackSurfaceView(engine: coordinator.engine)
                }
                AppleTransportOverlay(
                    coordinator: coordinator,
                    request: request,
                    onRequestFullScreen: {
                        lifetime.isFullScreen = true
                        showsSurfaceFullScreen = true
                    },
                    sharePlayMenu: sharePlayMenu
                )
            } else {
                #if os(macOS)
                AppleLiveMacPlayerRepresentable(playerView: host.playerView)
                #else
                AppleLivePlayerControllerRepresentable(
                    viewController: host.viewController,
                    captionsMenu: captionsMenu,
                    liveMenu: sharePlayMenu,
                    onFullScreenChanged: { lifetime.isFullScreen = $0 }
                )
                #endif
            }
            if coordinator.phase.isBusy {
                AppleLiveConnectingArtwork(logoURL: logoURL)
                    .allowsHitTesting(false)
            }
        }
        .background(.black)
        #if !os(macOS)
        .fullScreenCover(isPresented: $showsSurfaceFullScreen, onDismiss: { lifetime.isFullScreen = false }) {
            AppleLiveSurfaceFullScreenPlayer(coordinator: coordinator, request: request, sharePlayMenu: sharePlayMenu)
        }
        #endif
        .task(id: "\(requestIdentity):\(playbackRevision):\(scenePhase == .background)") {
            coordinator.sharePlayChannel = sharedChannel
            if scenePhase == .background, !request.isLive {
                let position = coordinator.engine.position
                if position.isFinite, position >= 0 {
                    suspendedRequestID = requestIdentity
                    suspendedPosition = position
                    suspendedWasPlaying = coordinator.engine.phase != .paused
                }
            }
            guard scenePhase != .background else {
                lifetime.stop(host: host, coordinator: coordinator)
                return
            }
            // SwiftUI can restart this task when a full-screen cover returns.
            // Only a new channel/retry or a real stop needs a new player item.
            guard lifetime.beginLoad(identity: "\(requestIdentity):\(playbackRevision)") else { return }
            coordinator.stop()
            host.activate()
            host.configureLivePlaybackControls()
            try? await audioSession.prepareForPlayback()
            guard !Task.isCancelled else { return }
            var playbackRequest = request
            let keepPaused = !request.isLive && suspendedRequestID == requestIdentity && suspendedWasPlaying == false
            if !request.isLive, suspendedRequestID == requestIdentity {
                playbackRequest.resumePosition = suspendedPosition
            }
            if keepPaused { playbackRequest.autoplay = false }
            suspendedRequestID = nil
            suspendedPosition = nil
            suspendedWasPlaying = nil
            await coordinator.begin(playbackRequest)
        }
        .onDisappear {
            lifetime.inlineDisappeared(host: host, coordinator: coordinator)
        }
        .alert("Playback Failed", isPresented: failureBinding) {
            Button("Retry") { Task { await coordinator.retry() } }
            Button("Close", role: .cancel) { coordinator.stop() }
        } message: {
            if case .failed(let failure) = coordinator.phase {
                Text(failure.message)
            }
        }
    }

    private var requestIdentity: String {
        "\(request.mediaID)|\(request.url.absoluteString)"
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed(let failure) = coordinator.phase { return failure.kind != .cancelled }
                return false
            },
            set: { if !$0 { coordinator.reset() } }
        )
    }

    #if os(macOS)
    private var sharePlayMenu: AppleTransportOverlay.SharePlayMenu? { nil }
    #else
    private var captionsMenu: UIMenu {
        let tracks = coordinator.engine.subtitleTracks
        let children: [UIMenuElement]
        if tracks.isEmpty {
            children = [UIAction(title: "This stream has no captions.", attributes: .disabled) { _ in }]
        } else {
            children = [UIAction(title: "Off") { _ in coordinator.engine.selectSubtitleTrack(id: nil) }] + tracks.map { track in
                UIAction(title: track.title) { _ in coordinator.engine.selectSubtitleTrack(id: track.id) }
            }
        }
        return UIMenu(title: "Captions", image: UIImage(systemName: "captions.bubble"), children: children)
    }

    private var sharePlayMenu: AppleTransportOverlay.SharePlayMenu? {
        guard let liveChannel else { return nil }
        if sharePlay.isActive {
            return .init(
                primaryTitle: "Leave SharePlay",
                primaryAction: { sharePlay.leave() },
                secondaryTitle: "End SharePlay for Everyone",
                secondaryAction: { sharePlay.endForEveryone() }
            )
        }
        return .init(primaryTitle: "Start SharePlay", primaryAction: { Task { await sharePlay.start(channel: liveChannel) } })
    }
    #endif
}

#if os(macOS)
private struct AppleLiveMacPlayerRepresentable: NSViewRepresentable {
    let playerView: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView { playerView }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
#else
private struct AppleLivePlayerControllerRepresentable: UIViewControllerRepresentable {
    let viewController: AVPlayerViewController
    let captionsMenu: UIMenu
    let liveMenu: AppleTransportOverlay.SharePlayMenu?
    let onFullScreenChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> AppleLivePlayerContainerViewController {
        AppleLivePlayerContainerViewController(playerViewController: viewController, captionsMenu: captionsMenu, liveMenu: liveMenu, onFullScreenChanged: onFullScreenChanged)
    }

    func updateUIViewController(_ vc: AppleLivePlayerContainerViewController, context: Context) {
        vc.updateMenus(captionsMenu: captionsMenu, liveMenu: liveMenu)
        vc.attachPlayerIfNeeded()
    }
}
#endif

#if !os(macOS)
private struct AppleLiveSurfaceFullScreenPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: ApplePlaybackCoordinator
    let request: ApplePlaybackRequest
    let sharePlayMenu: AppleTransportOverlay.SharePlayMenu?

    var body: some View {
        ApplePlaybackSurfaceView(engine: coordinator.engine)
            .ignoresSafeArea()
            .overlay {
                AppleTransportOverlay(
                    coordinator: coordinator,
                    request: request,
                    onClose: { dismiss() },
                    sharePlayMenu: sharePlayMenu
                )
            }
            .background(.black)
    }
}

/// Keeps the single AVPlayerViewController mounted while a live player moves
/// between the guide and a full-screen modal. Re-parenting this controller,
/// instead of rebuilding it on a size-class change, preserves the current item
/// and lets AVKit resize its layer during rotation.
private final class AppleLivePlayerContainerViewController: AppleLiveChromeViewController {
    private let playerViewController: AVPlayerViewController
    private var captionsMenu: UIMenu
    private var liveMenu: AppleTransportOverlay.SharePlayMenu?
    private var captionsButton: UIButton!
    private var fullscreenButton: UIButton!
    private weak var presentedFullscreen: AppleLiveFullscreenPlayerViewController?
    private let onFullScreenChanged: (Bool) -> Void

    init(playerViewController: AVPlayerViewController, captionsMenu: UIMenu, liveMenu: AppleTransportOverlay.SharePlayMenu?, onFullScreenChanged: @escaping (Bool) -> Void) {
        self.playerViewController = playerViewController
        self.onFullScreenChanged = onFullScreenChanged
        self.captionsMenu = captionsMenu
        self.liveMenu = liveMenu
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        captionsButton = menuButton(imageName: "captions.bubble", accessibilityLabel: "Captions", menu: captionsMenu)
        fullscreenButton = menuButton(imageName: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "Full Screen", menu: nil)
        fullscreenButton.addTarget(self, action: #selector(requestFullScreen), for: .primaryActionTriggered)
        view.addSubview(captionsButton)
        view.addSubview(fullscreenButton)
        NSLayoutConstraint.activate([
            captionsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            captionsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            fullscreenButton.topAnchor.constraint(equalTo: captionsButton.topAnchor),
            fullscreenButton.trailingAnchor.constraint(equalTo: captionsButton.leadingAnchor, constant: -8),
        ])
        chromeButtons = [captionsButton, fullscreenButton]
        attachPlayerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachPlayerIfNeeded()
    }

    func attachPlayerIfNeeded() {
        guard playerViewController.parent == nil, presentedFullscreen == nil else { return }
        playerViewController.showsPlaybackControls = true
        playerViewController.videoGravity = .resizeAspect
        addChild(playerViewController)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(playerViewController.view, at: 0)
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)
    }

    func updateMenus(captionsMenu: UIMenu, liveMenu: AppleTransportOverlay.SharePlayMenu?) {
        self.captionsMenu = captionsMenu
        self.liveMenu = liveMenu
        captionsButton?.menu = captionsMenu
    }

    func restorePlayer() {
        presentedFullscreen = nil
        attachPlayerIfNeeded()
        onFullScreenChanged(false)
        showControls()
    }

    @objc private func requestFullScreen() {
        guard presentedFullscreen == nil, playerViewController.presentingViewController == nil else { return }
        onFullScreenChanged(true)
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
        let fullscreen = AppleLiveFullscreenPlayerViewController(
            playerViewController: playerViewController,
            inlineContainer: self,
            captionsMenu: captionsMenu,
            liveMenu: liveMenu
        )
        presentedFullscreen = fullscreen
        // Retain the guide's view hierarchy and its loading task while AVKit
        // owns the single player controller in the modal.
        fullscreen.modalPresentationStyle = .overFullScreen
        present(fullscreen, animated: true)
    }
}

private final class AppleLiveFullscreenPlayerViewController: AppleLiveChromeViewController {
    private let playerViewController: AVPlayerViewController
    private let captionsMenu: UIMenu
    private let liveMenu: AppleTransportOverlay.SharePlayMenu?
    private weak var inlineContainer: AppleLivePlayerContainerViewController?

    init(playerViewController: AVPlayerViewController, inlineContainer: AppleLivePlayerContainerViewController, captionsMenu: UIMenu, liveMenu: AppleTransportOverlay.SharePlayMenu?) {
        self.playerViewController = playerViewController
        self.inlineContainer = inlineContainer
        self.captionsMenu = captionsMenu
        self.liveMenu = liveMenu
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let captions = menuButton(imageName: "captions.bubble", accessibilityLabel: "Captions", menu: captionsMenu)
        view.addSubview(captions)
        let close = menuButton(imageName: "xmark", accessibilityLabel: "Close player", menu: nil)
        close.addTarget(self, action: #selector(closePlayer), for: .primaryActionTriggered)
        view.addSubview(close)
        chromeButtons = [captions, close]
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: captions.topAnchor),
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            captions.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            captions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
        if let liveMenu {
            let more = menuButton(imageName: "ellipsis", accessibilityLabel: "SharePlay", menu: liveMenu.uiMenu)
            view.addSubview(more)
            chromeButtons.append(more)
            NSLayoutConstraint.activate([
                more.topAnchor.constraint(equalTo: captions.topAnchor),
                more.trailingAnchor.constraint(equalTo: captions.leadingAnchor, constant: -8),
            ])
        }
        playerViewController.showsPlaybackControls = true
        playerViewController.videoGravity = .resizeAspect
        addChild(playerViewController)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(playerViewController.view, at: 0)
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
        inlineContainer?.restorePlayer()
    }

    @objc private func closePlayer() { dismiss(animated: true) }

    #if !os(tvOS)
    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    #endif
    #endif
}

/// Only the supplementary Live buttons use this timer; AVKit continues to own
/// transport, seeking, PiP and its own control visibility.
private class AppleLiveChromeViewController: UIViewController, UIGestureRecognizerDelegate {
    var chromeButtons: [UIButton] = []
    private var hideTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(showControls))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hideTask?.cancel()
    }

    @objc func showControls() {
        hideTask?.cancel()
        chromeButtons.forEach { $0.isHidden = false }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.chromeButtons.forEach { $0.isHidden = true }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touched = touch.view
        while let current = touched {
            if current is UIControl { showControls(); return false }
            touched = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func menuButton(imageName: String, accessibilityLabel: String, menu: UIMenu?) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = accessibilityLabel
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

}

#endif

private struct AppleLiveSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if isEnabled {
            content.searchable(text: $query, prompt: "Channels and groups")
        } else {
            content
        }
        #endif
    }
}

#if os(tvOS)
struct AppleTVChannelSearchEditor: View {
    @Binding var query: String

    var body: some View {
        Form {
            Section {
                TextField("Channel or group", text: $query)
            }
            if !query.isEmpty {
                Section {
                    Button("Clear Search", role: .destructive) {
                        query = ""
                    }
                }
            }
        }
        .navigationTitle("Search Channels")
    }
}
#endif

private extension View {
    @ViewBuilder
    func appleTVFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}

@MainActor
enum AppleSMBPlaybackRequestFactory {
    static func make(
        source: AppleSource,
        item: AppleLibraryItem,
        playbackURL: URL
    ) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: playbackURL,
            headers: [:],
            isLive: false,
            mediaID: AppleMediaIngestion.libraryRecord(source: source, item: item).id,
            title: AppleLibraryTitleParser.parse(item).title,
            sourceKind: .networkShare,
            hints: ApplePlaybackRequest.Hints(filename: item.name)
        )
    }
}

@MainActor
struct AppleLibraryView: View {
    @State private var library = AppleLocalLibraryStore.shared
    @State private var viewportSize: CGSize = .zero
    @AppStorage("openstream.library.sort") private var sort = AppleLibrarySort.added
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void

    private var groups: [AppleLibrarySeries] { library.sorted(sort) }

    #if os(tvOS)
    private let sectionSpacing: CGFloat = AppleTVBillboardMetrics.sectionSpacing
    private let heroHorizontalPadding: CGFloat = -AppleTVChromeMetrics.horizontalSafeInset
    #else
    private let sectionSpacing: CGFloat = 30
    private let heroHorizontalPadding: CGFloat = 16
    #endif

    /// Nothing at all to draw: no titles, nothing in progress, no hero.
    ///
    /// The empty state is a sibling of the ScrollView rather than a row inside
    /// it, which is the only way it lands in the same place as Discover's.
    /// Inside the stack it was centred on `viewportSize − 32` while Discover's
    /// centred on the whole tab area, so "Open Settings" jumped 94 pt when the
    /// viewer flipped between the two empty tabs — measured y=504 against
    /// y=598 (owner: "when you flip the placement of open settings changes",
    /// 2026-09-16).
    private var hasNothingToShow: Bool {
        groups.isEmpty && library.continueWatching.isEmpty
            && library.featuredCandidates.isEmpty && !library.isLoading
    }

    var body: some View {
        Group {
            if hasNothingToShow {
                AppleSourceEmptyState(title: "No Videos", actionTitle: "Open Settings", action: openSettings)
            } else {
                libraryScroll
            }
        }
        .appleTraceScreen("library", detail: "\(groups.count) titles, loading=\(library.isLoading)")
    }

    /// Extracted from `libraryScroll` because the whole scroll body stopped
    /// type-checking on visionOS — "unable to type-check this expression in
    /// reasonable time", which is what had kept that target from building at all
    /// (2026-09-17). The visionOS branches add enough overloads to tip an
    /// expression the other platforms still managed. Same shape, one level of
    /// nesting moved out.
    @ViewBuilder
    private func rotatingHero(_ heroes: [AppleLibrarySeries]) -> some View {
        TimelineView(.periodic(from: .now, by: AppleHeroRotation.interval)) { context in
            if let index = AppleHeroRotation.index(at: context.date, count: heroes.count) {
                let featured = heroes[index]
                AppleFeaturedHero(
                    item: library.catalogItem(for: featured),
                    viewportSize: viewportSize,
                    rotationCount: heroes.count,
                    rotationIndex: index
                ) {
                    AppleFeaturedActions(viewportSize: viewportSize) {
                        detail(featured, autoPlay: true)
                    } detailDestination: { detail(featured) }
                }
                .padding(.horizontal, heroHorizontalPadding)
            }
        }
    }

    /// The per-source, per-kind shelves. Extracted for the same reason as
    /// `rotatingHero`: two nested `ForEach`es carrying four `let` bindings and a
    /// closure were more than the visionOS type-checker would finish.
    private var sourceShelves: some View {
        ForEach(library.sources) { source in
            let local = groups.filter { $0.items.first?.sourceID == source.id }
            ForEach([AppleLibraryTitle.Kind.movie, .show, .other], id: \.rawValue) { kind in
                let titles = local.filter { $0.parsed.kind == kind }
                if !titles.isEmpty {
                    // One library source reads "Movies" / "Shows"; the
                    // source name only disambiguates when there are several (Z9).
                    let kindName = kind == .movie ? "Movies" : kind == .show ? "Shows" : "Other"
                    let name = library.sources.count > 1 ? "\(kindName) · \(source.name)" : kindName
                    let isFirstShelf = accessoryShelf.map {
                        $0.sourceIndex == library.sources.firstIndex(where: { $0.id == source.id })
                            && $0.kind == kind
                    } ?? false
                    shelf(name, titles, accessory: isFirstShelf ? sortAccessory : nil)
                }
            }
        }
    }

    private var libraryScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                let heroes = library.featuredCandidates
                if !heroes.isEmpty {
                    rotatingHero(heroes)
                }
                if let error = library.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").padding(.horizontal, 16)
                }
                if !library.continueWatching.isEmpty { shelf("Continue Watching", library.continueWatching, progress: true) }
                sourceShelves
                if !groups.isEmpty { shelf("Recently Added", library.sorted(.added).prefix(24).map { $0 }) }
                if library.isLoading && groups.isEmpty {
                    AppleSourceLoadingState()
                        .appleCentredInViewport(viewportSize)
                }
            }
            #if os(tvOS)
            .padding(.bottom, AppleTVBillboardMetrics.contentBottomInset)
            #else
            .padding(.vertical)
            #endif
        }.scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        #if os(tvOS)
        // The billboard runs under the top safe area (see Discover). No
        // Refresh on a TV home (X4); Sort sits on the first shelf's header
        // line (`sortAccessory`), so nothing floats over the art.
        .ignoresSafeArea(edges: .top)
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        #else
        .toolbar {
            ToolbarItem(placement: libraryActionPlacement) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(AppleLibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort library", systemImage: "arrow.up.arrow.down") }
                #if os(visionOS)
                .buttonStyle(.borderless)
                .appleVisionActionTarget()
                #endif
            }
            ToolbarItem(placement: libraryActionPlacement) {
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .appleVisionActionTarget()
                    .disabled(library.isLoading)
            }
        }
        #endif
        .refreshable { await reload() }
        .task { library.refreshProgress(); if library.groups.isEmpty { await reload() } }
        .onAppear { library.refreshProgress() }
    }
    private var libraryActionPlacement: ToolbarItemPlacement {
        #if os(visionOS)
        .bottomOrnament
        #else
        .primaryAction
        #endif
    }
    private func reload() async { await library.reload(sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settings) }
    private func shelf(_ title: String, _ groups: [AppleLibrarySeries], progress: Bool = false, accessory: AnyView? = nil) -> some View {
        AppleLocalTitleShelf(title: title, groups: groups, sourceStore: sourceStore,
            mediaIndex: mediaIndex, settings: settings, openSettings: openSettings, showsProgress: progress, accessory: accessory)
    }

    /// The first kind a source actually has, so the Sort control lands on the
    /// first shelf drawn for the first source.
    /// The shelf that carries the sort control: the first one actually drawn.
    ///
    /// Not "the first source", which loses the control entirely when that
    /// source draws nothing — an offline NAS is enough to do it.
    private var accessoryShelf: (sourceIndex: Int, kind: AppleLibraryTitle.Kind)? {
        let perSource = library.sources.map { source -> [String] in
            let local = groups.filter { $0.items.first?.sourceID == source.id }
            return [AppleLibraryTitle.Kind.movie, .show, .other]
                .filter { kind in local.contains { $0.parsed.kind == kind } }
                .map(\.rawValue)
        }
        guard let pick = AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: perSource),
              let kind = AppleLibraryTitle.Kind(rawValue: pick.kind) else { return nil }
        return (pick.sourceIndex, kind)
    }

    private func firstKind(in local: [AppleLibrarySeries]) -> AppleLibraryTitle.Kind? {
        [AppleLibraryTitle.Kind.movie, .show, .other].first { kind in local.contains { $0.parsed.kind == kind } }
    }

    /// tvOS only: the Sort menu as a bare glyph on the first shelf's header
    /// line. Other platforms keep it in the toolbar.
    private var sortAccessory: AnyView? {
        #if os(tvOS)
        AnyView(
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(AppleLibrarySort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort library")
            .buttonStyle(AppleTVGlyphStyle())
            .font(.system(size: AppleTVChromeMetrics.glyphFontSize, weight: .semibold))
        )
        #else
        nil
        #endif
    }
    private func detail(_ group: AppleLibrarySeries, autoPlay: Bool = false) -> some View {
        AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
            settings: settings, openSettings: openSettings, autoPlay: autoPlay)
    }
}
