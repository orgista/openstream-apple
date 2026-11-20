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

    /// Waits out a reload already running, so one asked for meanwhile (a
    /// playlist added or edited, Try Again) runs after it instead of being
    /// dropped. Dropping it left Live on "No Live Channels" after a source
    /// was added during the launch reload (sim, 2026-10-08). False when the
    /// waiting task was cancelled.
    func waitUntilIdle() async -> Bool {
        while isRunning {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        return true
    }
}

@MainActor
struct AppleLiveTVView: View {
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleExpandsPhoneLayout) private var expandsPhoneLayout
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var channelIndex = AppleIPTVChannelIndex([])
    private var channels: [AppleIPTVChannel] { channelIndex.channels }
    @State private var channelSnapshot = AppleLiveChannelSnapshot(channels: [], channelIDs: [], categories: ["All", "Favorites"])
    @State private var channelsRevision = 0
    @State private var channelGroupTask: Task<Void, Never>?
    @State private var packageChoice: Task<Void, Never>?
    @State private var channelGroupIdentity: String?
    @State private var channelOrderIdentity: String?
    @State private var recallChannelIDs: Set<String> = []
    @State private var isLoading = false
    /// The first lineup load has answered (channels, an error or nothing).
    @State private var hasResolvedFirstLoad = false
    /// When Live first opened with no rows to show, until they show.
    @State private var firstOpenedAt: ContinuousClock.Instant?
    /// A lineup with channels in it has been sorted at least once; after that
    /// an empty list (Favorites, a search) is a result, not a load.
    @State private var hasSortedChannels = false
    @State private var errorMessage: String?
    /// Playlists that failed while others loaded; shown inline with Retry.
    @State private var sourceFailures: [AppleLiveSourceLoad.Failure] = []
    /// Playlists the running reload is still asking: their favorites stay on the system surfaces meanwhile.
    @State private var unansweredPlaylists: Set<UUID> = []
    /// Why each failed playlist failed, for the one-line failure states.
    @State private var sourceCauses: [UUID: AppleLiveFailureCause] = [:]
    /// One quiet retry of a playlist whose refresh failed under its saved channels.
    @State private var quietRetry: Task<Void, Never>?
    @State private var quietRetryUsed = false
    @State private var query = ""
    @State private var selectedCategory = "All"
    /// Pay-per-view channels in the lineup, for the Events tab.
    @State private var eventChannelCount = 0
    @State private var liveSession = AppleLiveSession()
    @State private var sourceConnectionLimits: [UUID: Int] = [:]
    @State private var hasEnteredLiveWhileActive = false
    private var selectedChannel: AppleIPTVChannel? {
        get { liveSession.channel }
        nonmutating set { liveSession.channel = newValue }
    }
    private var playbackRevision: Int {
        get { liveSession.playbackRevision }
        nonmutating set { liveSession.playbackRevision = newValue }
    }
    private var fullScreenRevision: Int {
        get { liveSession.fullScreenRevision }
        nonmutating set { liveSession.fullScreenRevision = newValue }
    }
    @State private var watchHistory = AppleLiveWatchHistoryStore.shared
    @AppStorage(AppleLiveWatchHistoryStore.resumeKey) private var startWithLastChannel = true
    private var resumePending: Bool {
        get { liveSession.resumePending }
        nonmutating set { liveSession.resumePending = newValue }
    }
    private var lastWatchedChannelID: String { watchHistory.history.channelIDs.first ?? "" }
    @State private var guideStore = AppleIPTVGuideStore()
    @State private var guideConfiguration = AppleLiveGuideConfiguration()
    @State private var completeGuide: [AppleChannelLineupEntry] = []
    @State private var lineupIndex = AppleChannelLineupIndex([])
    private var playbackCoordinator: ApplePlaybackCoordinator {
        get { liveSession.coordinator }
        nonmutating set { liveSession.coordinator = newValue }
    }
    @State private var configuredEngine: ApplePlaybackEngineKind?
    @FocusState private var focusedChannelID: String?
    @State private var reloadGate = AppleReloadGate()
    @State private var sharePlay = AppleSharePlaySessionStore.shared
    @State private var sharedChannelChoices: [AppleIPTVChannel] = []
    @State private var showsSharedChannelChoices = false
    #if DEBUG
    @State private var debugSharedChoicesShown = false
    #endif
    @State private var showsSearch = false
    /// Bumped to take the Live Search page down (`AppleLiveSearchModifier`).
    @State private var searchDismissal = 0
    @State private var healthStore = AppleChannelHealthStore.shared
    /// This lineup's health, rebuilt when the snapshot or the history moves —
    /// never per row render.
    @State private var channelHealth: [String: AppleChannelHealthResult] = [:]
    @State private var channelHealthRevision = 0
    @State private var snapshotRevision = 0
    @State private var healthDetailChannel: AppleIPTVChannel?
    #if os(macOS) || os(visionOS)
    /// The channel in the window's full player, while it is up.
    @State private var fullWindowPlayer: AppleMediaPlayerPresentation?
    #endif
    #if os(iOS) || os(visionOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewportSize: CGSize = .zero
    /// The side column the stage's video runs under (`AppleHeroSideColumn`).
    @State private var stageSideInsets = EdgeInsets()
    @State private var showsGuide = false
    #endif
    #if os(tvOS)
    private var tvMultiviewChannels: [AppleIPTVChannel] {
        get { liveSession.multiviewChannels }
        nonmutating set { liveSession.multiviewChannels = newValue }
    }
    @State private var tvPlayer: AppleTVLivePlayerPresentation?
    @State private var pictureInPicture = AppleTVPictureInPicture.shared
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
    var isActive = true

    private let client = AppleIPTVClient()

    var body: some View {
        @Bindable var settings = settings

        Group {
            if hasLiveSources, channels.isEmpty, showsChannelsLoading {
                #if os(iOS) || os(visionOS)
                // The stage stays black and the list area loads, also while a dead playlist
                // has already failed and the others are still loading.
                liveStage
                #else
                AppleLiveChannelsLoading()
                #endif
            } else if !hasResolvedFirstLoad, channels.isEmpty {
                // Nothing until the first load answers: "No Live Channels"
                // used to flash before the lineup drew.
                Color.clear
            } else if channels.isEmpty, errorMessage != nil, let cause = tabFailureCause, cause.action != .tryAgain {
                AppleLiveFailureCard(cause: cause, size: .tab) { perform(cause.action) }
            } else if channels.isEmpty, !hasLiveSources, isIOS {
                AppleLiveFailureCard(cause: .noSources, size: .tab) { perform(.addSource) }
            } else if channels.isEmpty, errorMessage != nil, !isIOS {
                // A panel that timed out may answer next time: Try Again
                // first, the settings that fix a wrong address under it. The
                // same page as Discover's "Couldn't Load Your Catalogs": the
                // system's error text ("Home IPTV: Could not connect to the
                // server.") used to be the headline (owner 2026-10-08: "looks
                // off and weird"); it stays in the trace.
                AppleSourceEmptyState(
                    title: "Couldn't Load Your Channels",
                    systemImage: OpenStreamTab.live.systemImage,
                    actionTitle: "Try Again",
                    action: { Task { await reload() } },
                    secondaryActionTitle: "Open Settings",
                    secondaryAction: openSettings
                )
            } else if channels.isEmpty, errorMessage == nil {
                AppleSourceEmptyState(
                    title: "No Live Channels",
                    systemImage: OpenStreamTab.live.systemImage,
                    actionTitle: "Open Settings",
                    action: openSettings
                )
            } else {
                #if os(tvOS)
                tvGuide
                #elseif os(iOS) || os(visionOS)
                liveStage
                #else
                #if os(iOS)
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                let isLandscape = isPad && (verticalSizeClass == .compact || viewportSize.width > viewportSize.height)
                #else
                let isLandscape = false
                #endif

                let videoColumn = VStack(spacing: 0) {
                    if let selectedChannel, !fullWindowHoldsChannel {
                        ZStack(alignment: .topTrailing) {
                            AppleLiveInlinePlayer(
                                request: playbackRequest(for: selectedChannel),
                                coordinator: playbackCoordinator,
                                playbackRevision: playbackRevision,
                                fullScreenRevision: fullScreenRevision,
                                logoURL: selectedChannel.logoURL,
                                sharedChannel: try? AppleSharePlayChannel(channel: selectedChannel),
                                sharePlay: sharePlay,
                                liveChannel: selectedChannel,
                                channels: channelSnapshot.channels,
                                otherListLineup: channelIndex,
                                sourceNames: liveSourceNames,
                                guide: guideStore.guide(for: playbackGuideChannelIDs),
                                onSwitchChannel: { startChannel($0, shareSelection: true, present: false) },
                                onLastChannel: lastChannelAction,
                                onStartOver: startOverAction,
                                onRequestFullWindow: fullWindowAction,
                                onCloseFullScreen: fullScreenPlayerClosed,
                                isConnecting: pendingProbe != nil
                            )
                            .id(ObjectIdentifier(playbackCoordinator))
                            
                            #if os(iOS)
                            HStack(spacing: 0) {
                                if isPad && verticalSizeClass == .compact {
                                    Button {
                                        showsSearch = true
                                    } label: {
                                        Image(systemName: "magnifyingglass")
                                            .frame(width: 44, height: 44)
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.3), radius: 2)
                                    }
                                    .padding()
                                }
                            }
                            #endif
                        }
                        #if os(iOS)
                        .livePinnedPlayerLayout(viewportSize: viewportSize, verticalSizeClass: verticalSizeClass)
                        #else
                        .livePinnedPlayerLayout()
                        #endif
                        .accessibilityLabel("Live player for \(selectedChannel.displayName)")
                        // Whether the picture is up, for VoiceOver and the
                        // owner-content Live check (a channel that never
                        // started read the same as one playing).
                        .accessibilityValue(playbackCoordinator.phase == .playing ? "Playing"
                            : (playbackCoordinator.phase.isBusy ? "Loading" : ""))
                    } else {
                        lastWatchedCard
                    }
                    #if os(iOS)
                    AppleLiveProgrammeLine(programme: selectedChannel.flatMap {
                        guideStore.guide(for: [$0.id]).nowAndNext(channelID: $0.id).now
                    })
                    #endif
                    if isLandscape {
                        Spacer(minLength: 0)
                    }
                }

                let guideColumn = VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: AppleDesignTokens.spacingLarge) {
                            ForEach(channelSnapshot.categories, id: \.self) { category in
                                Button { selectedCategory = category } label: {
                                    Text(category)
                                        .font(AppleDesignTokens.fontSubheadline)
                                        .foregroundStyle(selectedCategory == category ? AppleDesignTokens.textPrimary : AppleDesignTokens.textSecondary)
                                        .padding(.vertical, 10)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(.rect)
                                }
                                #if os(visionOS)
                                // visionOS's default style puts the label on a
                                // white platter, which hid the white text.
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                #endif
                                .overlay(alignment: .bottom) {
                                    Capsule().fill(AppleDesignTokens.brandAccent)
                                        .frame(height: 2)
                                        .opacity(selectedCategory == category ? 1 : 0)
                                        .allowsHitTesting(false)
                                }
                                // The underline and the brighter text say which
                                // category is showing; neither reaches
                                // VoiceOver, which read all eleven pills
                                // identically (2026-09-19).
                                .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, AppleDesignTokens.spacingMedium)
                    }
                    .scrollIndicators(.never)

                    // One line, only when the cap kept channels off the guide.
                    // Not an explainer: the count is the whole message, and the
                    // way to narrow it is the package picker the viewer already
                    // has. Silent truncation was the thing to avoid.
                    // A playlist that failed while the others loaded and has
                    // nothing on screen in its place: one quiet line naming
                    // it, with Try Again. One whose saved channels are showing
                    // says nothing (owner 2026-10-08: a warning row with the
                    // system's error text over a working lineup "looks off").
                    ForEach(sourceFailures.filter { !$0.showsSavedChannels }) { failure in
                        HStack(spacing: AppleDesignTokens.spacingMedium) {
                            Text("Couldn't load \(failure.sourceName)")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Try Again") { Task { await reload() } }
                                .foregroundStyle(AppleDesignTokens.textPrimary)
                                .accessibilityLabel("Try \(failure.sourceName) Again")
                        }
                        .font(AppleDesignTokens.fontCaption)
                        .foregroundStyle(AppleDesignTokens.textSecondary)
                        .padding(.horizontal, AppleDesignTokens.spacingMedium)
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("live.sourceError")
                    }

                    if channelSnapshot.hiddenCount > 0 {
                        Text("Showing \(channelSnapshot.channels.count) of \(channelSnapshot.channels.count + channelSnapshot.hiddenCount) channels")
                            .font(AppleDesignTokens.fontCaption)
                            .foregroundStyle(AppleDesignTokens.textSecondary)
                            .padding(.horizontal, AppleDesignTokens.spacingMedium)
                            .accessibilityIdentifier("live.cap.notice")
                    }

                    AppleIPTVGuideGridView(
                        channels: channelSnapshot.channels,
                        guide: guideStore.guide(for: playbackGuideChannelIDs),
                        guideRevision: guideStore.revision,
                        entries: completeGuide,
                        favoriteIDs: settings.favoriteChannelIDs,
                favoriteOrder: selectedCategory == "Favorites" ? settings.favoriteLiveChannelOrder : [],
                        onSelect: play,
                        onToggleFavorite: toggleFavorite,
                        onVisibleChannels: refreshGuide,
                        health: channelHealth,
                        onShowHealth: { healthDetailChannel = $0 },
                        onSelectProgramme: playProgramme
                    )
                    .safeAreaPadding(.bottom, 8)
                }

                Group {
                    if isLandscape {
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                videoColumn
                                guideColumn
                                    .containerRelativeFrame(.vertical, count: 1, span: 1, spacing: 0)
                            }
                        }
                        .scrollIndicators(.hidden)
                    } else {
                        VStack(spacing: 0) {
                            videoColumn
                            guideColumn
                        }
                    }
                }
                #if os(iOS)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { viewportSize = $0 }
                #endif
                #endif
            }
        }
.modifier(AppleLiveSearchModifier(isEnabled: !channels.isEmpty, query: $query,
            showsSearch: $showsSearch, dismissal: searchDismissal, playbackRevision: playbackRevision,
            channelRequest: AppleLiveSystemChannels.shared.requestedChannelID
                ?? AppleProgrammeReminderStore.shared.requestedChannelID) {
            #if os(iOS) || os(visionOS)
            liveOnNowList(channels: channelSnapshot.channels, showsSourceProblems: false)
            #else
            AppleIPTVGuideGridView(
                channels: channelSnapshot.channels,
                guide: guideStore.guide(for: playbackGuideChannelIDs),
                guideRevision: guideStore.revision,
                entries: completeGuide,
                favoriteIDs: settings.favoriteChannelIDs,
                        favoriteOrder: selectedCategory == "Favorites" ? settings.favoriteLiveChannelOrder : [],
                onSelect: play,
                onToggleFavorite: toggleFavorite,
                onVisibleChannels: refreshGuide,
                health: channelHealth,
                onShowHealth: { healthDetailChannel = $0 },
                onSelectProgramme: playProgramme
            )
            #endif
        })
        #if os(iOS) || os(visionOS)
        // No "Live" title and no bar above the video: the tab bar names the
        // tab and search is a glyph in the category row (owner item 9).
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .modifier(AppleLiveTabBarBackground())
        #endif
        .environment(\.liveChannelSettings, settings)
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
        .onChange(of: isActive) { _, active in
            if active {
                liveAppeared()
            } else {
                hasEnteredLiveWhileActive = false
                resumePending = false
            }
        }
        .onChange(of: playbackCoordinator.phase) { _, phase in liveSession.notePlaybackPhase(phase) }
        .onChange(of: sourceConnectionLimits) { startFirstChannelIfNeeded() }
        .onChange(of: snapshotRevision) {
            if !channels.isEmpty { hasSortedChannels = true }
            // Time to rows, for the trace: what the launch prefetch is for (`AppleLivePrefetch`).
            guard let opened = firstOpenedAt, !channelSnapshot.channels.isEmpty else { return }
            firstOpenedAt = nil
            appleTrace("live rows \(channelSnapshot.channels.count) shown \(AppleLaunchMarks.milliseconds(opened.duration(to: .now)))ms after opening")
        }
        .onAppear { liveAppeared(); scheduleChannelGroups() }
        .onDisappear {
            quietRetry?.cancel()
            if !showsSearch {
                channelGroupTask?.cancel()
                channelGroupIdentity = nil
            }
        }
        .refreshable { await refreshGuide(Set(channelSnapshot.channelIDs), force: true) }
        .task(id: reloadIdentity) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppleChannelLineupStore.didChange).receive(on: RunLoop.main)) { _ in
            appleTraceStep("live lineup change") {
                completeGuide = AppleChannelLineupPresets.current
                lineupIndex = AppleChannelLineupIndex(completeGuide)
                selectedCategory = "All"
                channelOrderIdentity = nil
                channelsRevision &+= 1
            }
            packageChoice?.cancel()
            packageChoice = Task { await chooseAutomaticPackage() }
        }
        .task(id: "\(channelsRevision)|\(settings.guideTimeOffsets.sorted { $0.key < $1.key })|\(settings.guideChannelAssignments.sorted { $0.key < $1.key })|\(scenePhase != .background)|\(isActive)") {
            guard scenePhase != .background, isActive else { return }
            await refreshGuide(Set(channelSnapshot.channelIDs.prefix(AppleLivePrefetch.leadingCount)))
        }
        .task(id: "\(channelsRevision)|\(scenePhase != .background)|\(isActive)|\(guideStore.retryRevision)") {
            guard scenePhase != .background, isActive else { return }
            await guideStore.retryFailedVisible(channelIDs: Set(channelSnapshot.channelIDs))
        }

        .task(id: "\(AppleProgrammeReminderStore.shared.requestedChannelID ?? "")|\(channelsRevision)") {
            appleTraceStep("live reminder request") {
                if let id = AppleProgrammeReminderStore.shared.requestedChannelID, let channel = channelIndex[id] {
                    AppleProgrammeReminderStore.shared.requestedChannelID = nil
                    play(channel)
                }
            }
        }

        .task(id: "\(channelsRevision)|\(isLoading)|\(settings.favoriteChannelIDs.sorted())|\(settings.favoriteLiveChannelOrder)|\(watchHistory.history.channelIDs)") {
            publishLiveChannels()
        }
        .task(id: "\(AppleLiveSystemChannels.shared.requestedChannelID ?? "")|\(channelsRevision)|\(isLoading)") {
            appleTraceStep("live channel request") { consumeLiveChannelRequest() }
        }
        #if os(tvOS)
        // The window's full-screen button: the player comes back around the
        // channel in the window (the root has already switched to this tab).
        .task(id: "\(pictureInPicture.liveRestoreRequest)|\(isActive)") {
            guard isActive, pictureInPicture.takeLiveRestore() else { return }
            tvMultiviewChannels = []
            if tvPlayer == nil { tvPlayer = AppleTVLivePlayerPresentation() }
        }
        #endif

        .onChange(of: projectionIdentity, initial: true) {
            appleTraceStep("live projection change") { scheduleChannelGroups() }
        }
        .task(id: "\(selectedChannel?.id ?? "")|\(playbackRevision)|\(isActive)") {
            guard isActive, let selectedChannel else { return }
            await refreshGuide([selectedChannel.id])
        }
        .task { await healthStore.loadIfNeeded() }
        .task(id: "\(snapshotRevision)|\(healthStore.revision)") {
            channelHealth = appleTraceStep("live health map") { healthStore.map(for: channelSnapshot.channels) }
            channelHealthRevision &+= 1
            #if DEBUG
            if healthDetailChannel == nil, let channel = healthStore.takeDebugDetailChannel(from: channelSnapshot.channels) {
                healthDetailChannel = channel
            }
            #endif
        }
        .sheet(item: $healthDetailChannel) { channel in
            AppleChannelHealthDetailView(channel: channel, store: healthStore, guideStore: guideStore, settings: settings)
                #if os(iOS) || os(visionOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        #if os(macOS) || os(visionOS)
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $fullWindowPlayer))
        .onChange(of: fullWindowPlayer == nil) { _, closed in
            if closed {
                fullScreenPlayerClosed()
                if selectedChannel != nil { playbackRevision &+= 1 }
            }
        }
        #endif
        .task(id: "shareplay:\(sharePlay.revision):\(channelsRevision)") {
            appleTraceStep("live shareplay channel") { resolveSharedChannel() }
        }
        #if os(tvOS)
        // A page, not the dialog: tvOS drew the dialog's focused choice white
        // on white (N72). Menu pops it, which leaves as the dialog's Cancel did.
        .navigationDestination(isPresented: Binding(
            get: { showsSharedChannelChoices },
            set: { presented in
                guard !presented, showsSharedChannelChoices else { return }
                showsSharedChannelChoices = false
                sharePlay.leave()
            }
        )) {
            AppleTVSharedSourceChoicePage(
                choices: sharedSourceChoices,
                onChoose: { channel in
                    showsSharedChannelChoices = false
                    startChannel(channel, shareSelection: false)
                },
                onLeave: {
                    showsSharedChannelChoices = false
                    sharePlay.leave()
                }
            )
        }
        #else
        .confirmationDialog("Choose the source for this channel", isPresented: $showsSharedChannelChoices, titleVisibility: .visible) {
            ForEach(sharedSourceChoices) { choice in
                Button(choice.title) {
                    startChannel(choice.channel, shareSelection: false)
                }
            }
            Button("Leave SharePlay", role: .cancel) { sharePlay.leave() }
        }
        #endif
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
        .task(id: pendingProbe?.id) {
            guard probeSurfaceIsActive(isPlayer: false) else { return }
            await probePendingChannel()
        }
        .alert("Channel Unavailable", isPresented: probeFailureBinding(isPlayer: false)) {
            probeFailureActions
        } message: {
            Text(probeFailureMessage ?? "")
        }
        // The full-screen player owns the failure alert (Retry/Close). A second
        // alert here, bound to the same coordinator phase, collided with the
        // fullScreenCover and dismissed the player silently (2026-09-03).
    }

    /// iPhone and iPad: the whole-tab failure, from the first playlist that
    /// failed (one symbol, one title naming it, one button). One that only
    /// needs Try Again is a line in the channel list instead, under the
    /// player, categories and guide (owner checklist rows 44 and 46).
    private var tabFailureCause: AppleLiveFailureCause? {
        #if os(iOS)
        guard let failure = sourceFailures.first else { return nil }
        return sourceCauses[failure.id] ?? .loadFailed(source: failure.sourceName)
        #else
        return nil
        #endif
    }

    private var isIOS: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var hasLiveSources: Bool {
        sourceStore.sources.contains { $0.kind == .liveTV && $0.isEnabled }
    }

    private var showsChannelsLoading: Bool {
        AppleLiveChannelsLoadingPolicy.showsLoading(hasRows: !channelSnapshot.channels.isEmpty,
            hasChannels: !channels.isEmpty, isLoading: isLoading, hasResolvedFirstLoad: hasResolvedFirstLoad,
            showsFailure: errorMessage != nil || !sourceFailures.isEmpty,
            hasSortedChannels: hasSortedChannels)
    }

    private func perform(_ action: AppleLiveFailureCause.Action) {
        switch action {
        case .tryAgain: Task { await reload() }
        case .openSettings, .addSource, .nextChannel: openSettings()
        }
    }

    /// Each list's name by id, for "Watch on <list>".
    private var playbackGuideChannelIDs: [String] {
        let ids = channelSnapshot.channelIDs
        guard let id = selectedChannel?.id, !ids.contains(id) else { return ids }
        return ids + [id]
    }

    private var liveSourceNames: [UUID: String] {
        Dictionary(sourceStore.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var sharedSourceChoices: [AppleSharedChannelSourceChoice] {
        AppleSharedChannelSourceChoice.choices(
            for: sharedChannelChoices,
            sourceNames: Dictionary(sourceStore.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    /// macOS and visionOS: hands the channel to the window's full player and
    /// stops the pinned one, so one stream plays at a time. Nil elsewhere:
    /// iOS presents its own full-screen container. On Vision Pro a SharePlay
    /// session keeps that container too, because the window's player is
    /// not bound to the session.
    private var fullWindowAction: (() -> Void)? {
        #if os(visionOS)
        guard !sharePlay.isActive else { return nil }
        #endif
        #if os(macOS) || os(visionOS)
        return {
            guard let channel = selectedChannel else { return }
            playbackCoordinator.stop()
            let request = playbackRequest(for: channel)
            let alternates = AppleLiveChannelAlternates.playbackCandidates(
                for: channel, request: request, in: channels,
                hasRecentlyFailed: { ApplePlaybackFailureHistory.shared.contains($0) })
            fullWindowPlayer = AppleMediaPlayerPresentation(request: request, fallbackCandidates: alternates, settings: settings)
        }
        #else
        return nil
        #endif
    }

    /// Vision Pro: the pinned player leaves while the window's player shows
    /// the channel, so it cannot start the same stream underneath; it comes
    /// back, and picks the channel up again, when that player closes.
    private var fullWindowHoldsChannel: Bool {
        #if os(visionOS)
        fullWindowPlayer != nil
        #else
        false
        #endif
    }

    private var reloadIdentity: String {
        ApplePlaybackIdentity.digest(for: sourceStore.sources
            .filter { $0.kind == .liveTV }
            .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)" }
            .joined(separator: "\u{1f}"))
    }

    private var projectionIdentity: String {
        "\(channelsRevision)|\(projectionPreferencesIdentity)"
    }

    private var projectionPreferencesIdentity: String {
        ApplePlaybackIdentity.digest(for: [
            selectedCategory,
            query,
            settings.liveChannelScope.rawValue,
            settings.regionalZIPCode,
            String(settings.showPayPerViewChannels),
            String(settings.show24x7Channels),
            settings.liveChannelPackage.rawValue,
            settings.customChannelPackage.identity,
            settings.favoriteChannelIDs.sorted().joined(separator: "\u{1f}"),
            String(AppleRestrictionStore.shared.revision),
            settings.hiddenLiveChannelIDs.sorted().joined(separator: "\u{1f}"),
            settings.hiddenLiveGroups.sorted().joined(separator: "\u{1f}"),
            settings.favoriteLiveChannelOrder.joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}"))
    }

    private func updateAutomaticPreview() async {
        await AppleIPTVAccountLimits.shared.registerSourceStore(sourceStore, sourceIDs: Set(sourceStore.sources.map(\.id)))
        let limits = await AppleIPTVAccountLimits.shared.snapshot()
        guard !Task.isCancelled else { return }
        sourceConnectionLimits = limits
    }

    private func allowsAutomaticPreview(_ channel: AppleIPTVChannel) -> Bool {
        AppleIPTVPreviewActivity.shared.allowsAutomaticPreview(sourceID: channel.sourceID,
            maximumConnections: sourceConnectionLimits[channel.sourceID])
    }

    private func fullScreenPlayerClosed() {
        guard let channel = selectedChannel else { return }
        liveSession.closeFullScreen(maximumConnections: sourceConnectionLimits[channel.sourceID])
    }

    private func reload() async {
        guard await reloadGate.waitUntilIdle(), reloadGate.begin() else { return }
        defer {
            reloadGate.end()
            if !Task.isCancelled { hasResolvedFirstLoad = true }
        }
        completeGuide = AppleChannelLineupPresets.current
        lineupIndex = AppleChannelLineupIndex(completeGuide)
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        await AppleIPTVChannelCache.shared.retain(Set(sources.map(\.id)))
        await updateAutomaticPreview()
        guard !sources.isEmpty else {
            settings.updateAutomaticLiveChannelPackage(channels: [])
            unansweredPlaylists = []
            channelIndex = AppleIPTVChannelIndex([])
            channelsRevision &+= 1
            errorMessage = nil
            sourceFailures = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        // Show the saved lineup first. Re-fetching all 9376 of the owner's
        // channels took 2137 ms before the guide could draw anything
        // (2026-09-15); a lineup changes rarely, so the saved copy goes up at
        // once and the network answer replaces it underneath.
        var cached: [UUID: [AppleIPTVChannel]] = [:]
        var cachedDates: [UUID: Date] = [:]
        let restoreStarted = ContinuousClock.now
        for source in sources {
            if let snapshot = await AppleIPTVChannelCache.shared.snapshot(for: source.id) {
                cached[source.id] = snapshot.channels
                if !snapshot.channels.isEmpty { cachedDates[source.id] = snapshot.storedAt }
            }
        }
        appleTrace("live cache restored channels=\(cached.values.reduce(0) { $0 + $1.count }) ms=\(AppleLaunchMarks.milliseconds(restoreStarted.duration(to: .now)))")
        var load = AppleLiveSourceLoad(sources: sources, cached: cached)
        unansweredPlaylists = load.unanswered
        if channels.isEmpty, !load.channels.isEmpty, !Task.isCancelled {
            await publish(load)
            #if DEBUG
            AppleLaunchClock.mark("live.cached(\(load.channels.count))")
            #endif
        }

        // Every playlist at once: a dead panel's timeout no longer holds up
        // the others, and each one's channels go up as it answers.
        let iptvClient = client
        var requests: [(source: AppleSource, credentials: AppleIPTVCredentials?)] = []
        for source in sources {
            do {
                let credentials = try sourceStore.iptvCredentials(for: source)
                if source.iptvType == .xtream, credentials == nil { throw AppleIPTVError.missingCredentials }
                requests.append((source, credentials))
            } catch {
                let message = AppleIPTVFailureCause.message(for: error, providerName: source.name)
                sourceStore.recordPlaylistRefreshFailure(id: source.id, error: error, savedAt: cachedDates[source.id])
                load.failed(source.id, message: message)
                sourceCauses[source.id] = .source(error, sourceName: source.name)
            }
        }
        let completed = await AppleLiveSourceLoad.collect(requests, fetch: { request in
            do {
                let started = ContinuousClock.now
                let received = try await AppleLivePlaylistFetches.shared.channels(
                    source: request.source, credentials: request.credentials, client: iptvClient)
                appleTrace("live playlist answered: \(received.count) channels in \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms")
                return (request.source, .success(received))
            } catch {
                return (request.source, .failure(error))
            }
        }, answer: { source, result in
            await updateAutomaticPreview()
            switch result {
            case .success(let receivedChannels):
                let sourceChannels = await AppleIPTVChannelCache.shared.reconcileAndStore(receivedChannels, for: source.id)
                load.succeeded(source.id, channels: sourceChannels)
                sourceCauses[source.id] = nil
                appleTraceStep("live answer source save") {
                    sourceStore.recordValidationSuccess(
                        id: source.id,
                        summary: "Connected · \(sourceChannels.count) channels",
                        discoveredItemCount: sourceChannels.count,
                        capabilities: ["Live channels", "Playback"]
                    )
                }
                // A digest per channel: too much for the main actor on a lineup of thousands.
                let records = await Task.detached(priority: .userInitiated) {
                    AppleMediaIngestion.channelRecords(source: source, channels: sourceChannels)
                }.value
                guard !Task.isCancelled else { return false }
                try? await mediaIndex.replace(instanceID: source.id, with: records)
            case .failure(let error):
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return false }
                // Names the provider, and calls a panel that did not answer unreachable rather than a stream limit.
                let message = AppleIPTVFailureCause.message(for: error, providerName: source.name)
                sourceStore.recordPlaylistRefreshFailure(id: source.id, error: error, savedAt: cachedDates[source.id])
                load.failed(source.id, message: message)
                sourceCauses[source.id] = .source(error, sourceName: source.name)
            }
            return true
        }, publish: {
            await publish(load)
            appleTraceStep("live answer publish") {
                unansweredPlaylists = load.unanswered
                sourceFailures = load.failures
                if !load.channels.isEmpty {
                    isLoading = false
                    hasResolvedFirstLoad = true
                }
                startFirstChannelIfNeeded()
            }
            appleTraceMainQueueSettle("live answer publish")
        })
        guard completed else { return }
        #if DEBUG
        AppleLaunchClock.mark("live.channels(\(load.channels.count))")
        #endif
        sourceFailures = load.failures
        errorMessage = load.failures.first?.text
        for failure in load.failures {
            appleTrace("live playlist failed: \(failure.sourceName) saved=\(failure.showsSavedChannels) \(failure.message)")
        }
        scheduleQuietRetry(after: load.failures)
        startFirstChannelIfNeeded()
    }

    /// A provider that timed out under its saved lineup is asked once more, half a minute
    /// later, with no card and no row: the viewer is already watching the saved channels.
    private func scheduleQuietRetry(after failures: [AppleLiveSourceLoad.Failure]) {
        quietRetry?.cancel()
        guard failures.contains(where: \.showsSavedChannels) else {
            quietRetryUsed = false
            return
        }
        guard !quietRetryUsed else { return }
        quietRetryUsed = true
        quietRetry = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            appleTrace("live playlist quiet retry")
            await reload()
        }
    }

    /// Fills the player with the last-watched channel (or the first) once
    /// any playlist has answered, rather than after the slowest one.
    private func startFirstChannelIfNeeded() {
        let last = startWithLastChannel ? lastWatchedChannel : nil
        let availableLast = last.flatMap { saved in channelSnapshot.channels.first { $0.id == saved.id } }
        if isActive, selectedChannel == nil, !sharePlay.isActive,
           let channel = availableLast ?? channelSnapshot.channels.first,
           allowsAutomaticPreview(channel) {
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
                if hops > 0 { scheduleDebugChannelHops(count: hops, from: channel, in: channels) }
            }
            #elseif DEBUG
            // The same hops in the inline player, through the guide's own
            // order, so a provider's start-up times can be measured
            // headlessly on a phone simulator (trace: "first frame").
            let hops = UserDefaults.standard.integer(forKey: "OpenStreamLiveAutoSwitchCount")
            if hops > 0 { scheduleDebugChannelHops(count: hops, from: channel, in: channelSnapshot.channels, present: false) }
            #endif
        }
        #if DEBUG
        // `OpenStreamDebugSharedChannelChoices YES` opens the SharePlay
        // "Choose the source for this channel" dialog over the first two
        // channels, so it can be photographed without a real SharePlay
        // session. Nothing is chosen; Menu leaves it as Leave SharePlay does.
        // Once per launch: the lineup loads twice (cache, then network), and a
        // second pass re-opened the prompt the viewer had just left.
        if UserDefaults.standard.bool(forKey: "OpenStreamDebugSharedChannelChoices"),
           !debugSharedChoicesShown, !sharePlay.isActive, channels.count > 1 {
            debugSharedChoicesShown = true
            sharedChannelChoices = Array(channels.prefix(2))
            showsSharedChannelChoices = true
        }
        #endif
    }

    #if DEBUG
    /// Simulator only: walk to the next channels every few seconds so the
    /// switch path can be captured. Never reachable without the default set.
    private func scheduleDebugChannelHops(count: Int, from channel: AppleIPTVChannel,
                                          in list: [AppleIPTVChannel], present: Bool = true) {
        guard let start = list.firstIndex(where: { $0.id == channel.id }), list.count > 1 else { return }
        let gap = UserDefaults.standard.object(forKey: "OpenStreamLiveAutoSwitchSeconds") as? Double ?? 8
        Task { @MainActor in
            for hop in 1 ... count {
                try? await Task.sleep(for: .seconds(max(0.2, gap)))
                let next = list[(start + hop) % list.count]
                print("[OpenStream] debug channel hop \(hop) -> \(next.name)")
                appleTrace("debug channel hop \(hop) -> \(next.name)")
                startChannel(next, shareSelection: false, present: present)
            }
        }
    }
    #endif

    /// The slice of the channel strip worth fetching EPG for: the channel being
    /// watched and its neighbours either side. Bounded, because the lineup can
    /// be thousands long and the strip only ever shows a handful at a time.
    private func stripGuideChannelIDs(around channel: AppleIPTVChannel, radius: Int = 20) -> [String] {
        AppleLiveZappingPolicy.guideNeighborhood(currentID: channel.id,
            orderedIDs: channelSnapshot.channelIDs, radius: radius)
    }

    /// Puts the merged lineup up; the index and the automatic package are built off the main actor.
    private func publish(_ load: AppleLiveSourceLoad) async {
        let packageInput = settings.automaticLiveChannelPackageInput
        let publication = await load.publication(packageEntries: packageInput?.entries)
        guard !Task.isCancelled else { return }
        let packageIsCurrent = appleTraceStep("live lineup publish") {
            channelIndex = publication.index
            channelsRevision &+= 1
            guard let package = publication.package, let packageInput else { return true }
            return settings.setAutomaticLiveChannelPackage(package, chosenFrom: packageInput)
        }
        if !packageIsCurrent { await chooseAutomaticPackage() }
    }

    /// Chooses the automatic package for the lineup now up, off the main
    /// actor. Dropped if the lineup or the guide lineup changed meanwhile;
    /// whatever changed them chooses again.
    private func chooseAutomaticPackage() async {
        guard let input = settings.automaticLiveChannelPackageInput else { return }
        let index = channelIndex
        let package = await Task.detached(priority: .userInitiated) {
            AppleLiveChannelPackage.defaultPackage(for: index.channels, entries: input.entries)
        }.value
        guard !Task.isCancelled, channelIndex == index else { return }
        settings.setAutomaticLiveChannelPackage(package, chosenFrom: input)
    }

    private func refreshGuide(_ visibleIDs: Set<String>) async {
        await refreshGuide(visibleIDs, force: false)
    }

    private func refreshGuide(_ visibleIDs: Set<String>, force: Bool) async {
        guard !visibleIDs.isEmpty else { return }
        if force { await AppleArtworkDiskCache.shared.clearFailures(for: channels.compactMap(\.logoURL)) }
        let started = ContinuousClock.now
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        let key = AppleLiveGuideConfiguration.key(sources: sources, channelsRevision: channelsRevision,
            timeOffsets: settings.guideTimeOffsets, assignments: settings.guideChannelAssignments)
        if guideConfiguration.needsConfigure(key, force: force) {
            let complete = appleTraceStep("live guide configure") {
                guideStore.configure(liveSources: sources, channels: channels, sourceStore: sourceStore, settings: settings)
            }
            guideConfiguration.didConfigure(key, complete: complete)
        }
        let leading = channels.filter { visibleIDs.contains($0.id) }.prefix(AppleLivePrefetch.leadingCount)
        async let logos = AppleRemoteImageCache.shared.warm(
            AppleLivePrefetch.logoRequests(Array(leading), displayScale: displayScale),
            width: AppleLivePrefetch.logoWidth, deadline: AppleLivePrefetch.logoDeadline)
        await guideStore.refreshVisible(channelIDs: visibleIDs, force: force)
        let filled = visibleIDs.filter { guideStore.nowAndNext(channelID: $0).now != nil }.count
        appleTrace("live visible guide channels=\(filled)/\(visibleIDs.count) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
        _ = await logos
    }

    private func liveAppeared() {
        guard isActive else { return }
        guard !hasEnteredLiveWhileActive else {
            liveSession.refreshScreenLabel()
            return
        }
        hasEnteredLiveWhileActive = true
        if channelSnapshot.channels.isEmpty, firstOpenedAt == nil { firstOpenedAt = .now }
        liveSession.enterLive()
        resumeLastChannelIfNeeded()
        startFirstChannelIfNeeded()
    }

    private func scheduleChannelGroups() {
        let identity = projectionIdentity
        guard channelGroupIdentity != identity else { return }
        channelGroupTask?.cancel()
        channelGroupIdentity = identity
        channelGroupTask = Task { await rebuildChannelGroups(identity: identity) }
    }

    private func rebuildChannelGroups(identity: String) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, projectionIdentity == identity else { return }
        }
        let lineup = channels
        let policy = AppleRestrictionStore.shared.policy
        let hasPIN = AppleRestrictionStore.shared.hasPIN
        let hiddenIDs = settings.hiddenLiveChannelIDs
        let hiddenGroups = settings.hiddenLiveGroups
        let visible = await Task.detached(priority: .userInitiated) {
            let permitted = lineup.filter { policy.isVisible(channelID: $0.id, group: $0.group, hasPIN: hasPIN) }
            return AppleLiveChannelPreferences.visible(permitted, hiddenIDs: hiddenIDs, hiddenGroups: hiddenGroups)
        }.value
        guard !Task.isCancelled, projectionIdentity == identity else { return }
        let updated = await AppleChannelProjection.buildGroupsOffMain(
            from: visible,
            scope: settings.liveChannelScope,
            showPayPerView: settings.showPayPerViewChannels,
            favoriteIDs: settings.favoriteChannelIDs,
            query: clean,
            regionalZIPCode: settings.regionalZIPCode,
            show24x7: settings.liveChannelPackage == .custom || settings.show24x7Channels
        )
        guard !Task.isCancelled, projectionIdentity == identity else { return }
        #if DEBUG
        AppleLaunchClock.mark("live.groups(\(updated.count))")
        #endif
        let package = settings.liveChannelPackage
        let custom = settings.customChannelPackage
        let entries = completeGuide
        let favorites = settings.favoriteChannelIDs
        let category = selectedCategory
        let orderIdentity = projectionPreferencesIdentity
        let (snapshot, events, visibleIDs) = await Task.detached(priority: .userInitiated) {
            (AppleLiveChannelSnapshot.build(groups: updated, package: package, custom: custom,
                entries: entries, favoriteIDs: favorites, category: category),
             AppleLiveCategoryOrder.eventChannels(visible), Set(visible.map(\.id)))
        }.value
        guard !Task.isCancelled, projectionIdentity == identity else { return }
        #if DEBUG
        print("[OpenStream] live lineup source=\(channels.count) package=\(package.title) guide=\(snapshot.channels.count) categories=\(snapshot.categories.count)")
        AppleLaunchClock.mark("live.snapshot(\(snapshot.channels.count))")
        #endif
        appleTraceStep("live groups apply") {
            recallChannelIDs = visibleIDs
            // Both guides use this number/favorite projection; zaps and the
            // strip must follow it rather than the pre-sort playlist order.
            var ordered = AppleGuideChannelProjection.rows(channels: snapshot.channels, entries: entries,
                favoriteIDs: favorites, favoritesOnly: false, sortByNumber: true,
                favoriteOrder: category == "Favorites" ? settings.favoriteLiveChannelOrder : []).map(\.channel)
            var hiddenCount = snapshot.hiddenCount
            // Events (iPhone and iPad): the lineup's pay-per-view channels, shown
            // whether or not "Show pay-per-view" is on (owner item 11).
            eventChannelCount = events.count
            if category == AppleLiveCategoryOrder.events {
                ordered = Array(events.prefix(AppleLiveChannelSnapshot.maximumDisplayedChannels))
                hiddenCount = max(0, events.count - ordered.count)
            }
            if channelOrderIdentity == orderIdentity {
                ordered = AppleStableRefresh.merge(channelSnapshot.channels, incoming: ordered, id: \.id)
            }
            channelOrderIdentity = orderIdentity
            channelSnapshot = AppleLiveChannelSnapshot(channels: ordered, channelIDs: ordered.map(\.id),
                categories: snapshot.categories, hiddenCount: hiddenCount)
            resumeLastChannelIfNeeded()
            startFirstChannelIfNeeded()
            snapshotRevision &+= 1
            // The health summary, sweep and export follow the All lineup the
            // guide shows; a category or a search is only a view of it.
            if category == "All", clean.isEmpty { healthStore.setLineup(snapshot.channels) }
            let availableIDs = Set(snapshot.channelIDs)
            if focusedChannelID == nil || !availableIDs.contains(focusedChannelID ?? "") {
                focusedChannelID = updated.first?.channels.first?.id
            }
        }
        appleTraceMainQueueSettle("live groups apply")
    }

    private func resumeLastChannelIfNeeded() {
        guard isActive, resumePending, !recallChannelIDs.isEmpty else { return }
        #if os(tvOS)
        guard AppleTVPictureInPicturePolicy.resumesLastChannelOnArrival(
            isPictureInPictureActive: pictureInPicture.isActive) else {
            resumePending = false
            return
        }
        #endif
        guard startWithLastChannel, !sharePlay.isActive,
              AppleProgrammeReminderStore.shared.requestedChannelID == nil else {
            resumePending = false
            return
        }
        guard !watchHistory.history.channelIDs.isEmpty else {
            resumePending = false
            return
        }
        let available = recallChannelIDs
        guard let id = liveSession.resumeTarget(enabled: startWithLastChannel, active: isActive,
            watchedIDs: watchHistory.history.channelIDs, availableIDs: available,
            lastWatchedAt: watchHistory.history.lastWatchedAt),
              let channel = channelIndex[id] else { return }
        resumePending = false
        guard allowsAutomaticPreview(channel) else { return }
        #if os(tvOS)
        startChannel(channel, shareSelection: false, present: true)
        #else
        startChannel(channel, shareSelection: false, present: false)
        #endif
    }

    private var previousWatchedChannel: AppleIPTVChannel? {
        guard let selectedChannel,
              let id = liveSession.previousID(currentID: selectedChannel.id, programme: catchUp,
                  history: watchHistory.history, availableIDs: recallChannelIDs) else { return nil }
        return channelIndex[id]
    }

    private var lastChannelAction: (() -> Void)? {
        guard previousWatchedChannel != nil else { return nil }
        return { recallLastChannel() }
    }

    private func recallLastChannel() {
        guard let channel = previousWatchedChannel else { return }
        AppleInteractionTrace.record(.press, "live zap \(selectedChannel?.name ?? "") → \(channel.name)")
        #if os(tvOS)
        startChannel(channel, shareSelection: true, present: true)
        #else
        startChannel(channel, shareSelection: true, present: false)
        #endif
    }

    private func publishLiveChannels() {
        guard !isLoading else { return }
        appleTraceStep("live system channels") {
            AppleLiveSystemChannels.shared.update(index: channelIndex, unanswered: unansweredPlaylists,
                favorites: settings.favoriteChannelIDs, favoriteOrder: settings.favoriteLiveChannelOrder,
                recentIDs: watchHistory.history.channelIDs)
        }
    }

    private func consumeLiveChannelRequest() {
        guard !channels.isEmpty, let id = AppleLiveSystemChannels.shared.requestedChannelID,
              AppleLiveZappingPolicy.handlesRequest(isLoading: isLoading, channelIsKnown: channelIndex[id] != nil)
        else { return }
        AppleLiveSystemChannels.shared.requestedChannelID = nil
        if let channel = channelIndex[id] {
            #if os(tvOS)
            tvMultiviewChannels = []
            #endif
            play(channel)
        }
        else { probeFailureMessage = "This channel is no longer available." }
    }

    private var startOverAction: (() -> Void)? {
        guard catchUp == nil, let channel = selectedChannel,
              let programme = guideStore.guide(for: [channel.id]).nowAndNext(channelID: channel.id).now,
              AppleIPTVCatchUp.canStartOver(programme, on: channel) else { return nil }
        return {
            #if os(tvOS)
            startChannel(channel, shareSelection: false, programme: programme)
            #else
            startChannel(channel, shareSelection: false, present: false, programme: programme)
            #endif
        }
    }

    private func dismissLiveSearch() {
        guard showsSearch else { return }
        searchDismissal &+= 1
    }

    private func play(_ channel: AppleIPTVChannel) {
        dismissLiveSearch()
        // The strip or a resume may already be starting this very channel
        // (a link or Siri asks for the last-watched one): keep that attempt.
        #if os(tvOS)
        let playerShown = tvPlayer != nil
        #else
        let playerShown = true
        #endif
        if playerShown, AppleLiveZappingPolicy.keepsCurrentAttempt(requestedID: channel.id,
            selectedID: selectedChannel?.id, isCatchUp: catchUp != nil, phase: playbackCoordinator.phase) {
            appleTrace("live play \(channel.name): already \(playbackCoordinator.phase.isBusy ? "starting" : "playing"), kept")
            sharePlay.selected(channel)
            #if os(visionOS)
            if let fullWindowAction { fullWindowAction() } else { fullScreenRevision &+= 1 }
            #elseif !os(tvOS)
            fullScreenRevision &+= 1
            #endif
            return
        }
        startChannel(channel, shareSelection: true)
    }

    /// A programme that already aired, from the channel's archive
    /// (`AppleIPTVCatchUp`). Not shared: SharePlay follows live channels.
    private func playProgramme(_ channel: AppleIPTVChannel, _ programme: AppleIPTVProgramme) {
        #if DEBUG
        AppleInteractionTrace.record(.press, "guide catch-up \(channel.name): \(programme.title) from \(programme.start.formatted(date: .omitted, time: .shortened))")
        #endif
        startChannel(channel, shareSelection: false, programme: programme)
    }

    /// The programme out of the archive being played on `selectedChannel`;
    /// nil while the channel is live. Cleared by every live start.
    private var catchUp: AppleIPTVProgramme? {
        get { liveSession.programme }
        nonmutating set { liveSession.programme = newValue }
    }

    /// What the player is asked to play for `channel`: the archived
    /// programme when one was chosen, else the live stream.
    private func playbackRequest(for channel: AppleIPTVChannel) -> ApplePlaybackRequest {
        liveSession.request(for: channel, programme: catchUp)
    }

    private var liveProbedKinds: [String: AppleIPTVStreamProbeResult.MediaKind] {
        liveSession.probedKinds
    }
    private typealias ChannelProbeRequest = AppleLiveSession.ProbeRequest
    private var pendingProbe: ChannelProbeRequest? {
        get { liveSession.pendingProbe }
        nonmutating set { liveSession.pendingProbe = newValue }
    }
    private var failedProbe: ChannelProbeRequest? {
        get { liveSession.failedProbe }
        nonmutating set { liveSession.failedProbe = newValue }
    }
    private var probeFailureMessage: String? {
        get { liveSession.probeFailureMessage }
        nonmutating set { liveSession.probeFailureMessage = newValue }
    }

    private func probePendingChannel() async {
        switch await liveSession.resolvePendingProbe() {
        case .ready(let request):
            startChannelNow(request.channel, shareSelection: request.shareSelection, present: request.present)
        case .failed(let request):
            #if os(iOS)
            probeFailureMessage = AppleLiveFailureCause.notBroadcasting(channel: request.channel.displayName).title
            #else
            _ = request
            #endif
        case .superseded: break
        }
    }

    private func probeSurfaceIsActive(isPlayer: Bool) -> Bool {
        #if os(tvOS)
        (tvPlayer != nil) == isPlayer
        #else
        !isPlayer
        #endif
    }

    private func probeFailureBinding(isPlayer: Bool) -> Binding<Bool> {
        Binding(
            get: { probeSurfaceIsActive(isPlayer: isPlayer) && probeFailureMessage != nil },
            set: { presented in
                guard !presented, probeSurfaceIsActive(isPlayer: isPlayer) else { return }
                probeFailureMessage = nil
            }
        )
    }

    @ViewBuilder
    private var probeFailureActions: some View {
        Button("Retry") {
            guard let request = failedProbe else { return }
            startChannel(request.channel, shareSelection: request.shareSelection, present: request.present,
                         programme: request.programme)
        }
        Button("Close", role: .cancel) { failedProbe = nil }
    }


    /// Every way a channel starts funnels through here. An extension-less URL
    /// gets one 32 KB look first so HLS goes to AVPlayer and raw TS to the
    /// engine (`AppleLiveStreamRoutePolicy`); the verdict is kept for the
    /// session. Anything with a telling extension starts at once.
    @State private var parentalPlayTask: Task<Void, Never>?
    private func startChannel(_ channel: AppleIPTVChannel, shareSelection: Bool, present: Bool = true,
                              programme: AppleIPTVProgramme? = nil) {
        parentalPlayTask?.cancel()
        #if os(tvOS)
        // Before anything stops the shared coordinator under the window.
        if present, AppleTVPictureInPicturePolicy.channelChoice(
            isPictureInPictureActive: pictureInPicture.isActive) == .closeWindowAndPlayFullScreen {
            pictureInPicture.endForNewPlayback()
        }
        #endif
        let restrictions = AppleRestrictionStore.shared
        guard restrictions.needsUnlock(channelID: channel.id, group: channel.group) else {
            startAuthorizedChannel(channel, shareSelection: shareSelection, present: present, programme: programme)
            return
        }
        // Retire the previous player's failure alert before presenting the PIN.
        playbackCoordinator.stop()
        pendingProbe = nil
        probeFailureMessage = nil
        parentalPlayTask = Task {
            guard await restrictions.authorize(channelID: channel.id, group: channel.group, title: channel.displayName),
                  !Task.isCancelled, !restrictions.needsUnlock(channelID: channel.id, group: channel.group) else { return }
            startAuthorizedChannel(channel, shareSelection: shareSelection, present: present, programme: programme)
        }
    }

    private func startAuthorizedChannel(_ channel: AppleIPTVChannel, shareSelection: Bool, present: Bool,
                                       programme: AppleIPTVProgramme?) {
        liveSession.beginSelection(programme: programme, shareSelection: shareSelection)
        liveSession.markTuneStarted(channel)
        guard channel.probedMediaKind == nil, AppleLiveStreamRoutePolicy.needsProbe(channel.streamURL) else {
            startChannelNow(channel, shareSelection: shareSelection, present: present)
            return
        }
        if let known = liveProbedKinds[channel.id] {
            startChannelNow(channel.withProbedMediaKind(known), shareSelection: shareSelection, present: present)
            return
        }
        // Retire the previous attempt before showing a new channel's failure.
        // Otherwise its player alert can cover the preflight's Retry/Close alert.
        playbackCoordinator.stop()
        pendingProbe = ChannelProbeRequest(channel: channel, shareSelection: shareSelection, present: present,
                                           programme: programme)
    }

    private func startChannelNow(_ channel: AppleIPTVChannel, shareSelection: Bool, present: Bool = true) {
        if shareSelection { sharePlay.selected(channel) }
        // Unknown HLS channels are eligible on their first start. The engine
        // validates the playlist and owns the cancellable caption observation.
        let channel = channel.withCaptionMaster(
            AppleLiveCaptionProbe.shared.wrapsInCaptionMaster(channelID: channel.id))
        #if os(tvOS)
        if present { ensureTVEngine(for: playbackRequest(for: channel)) }
        #endif
        playbackCoordinator.sharePlayChannel = try? AppleSharePlayChannel(channel: channel)
        playbackRevision &+= 1
        #if os(visionOS)
        selectedChannel = channel
        // The window's player, not AVKit's full-screen modal (which XCTest
        // cannot even leave on the simulator).
        if present { if let fullWindowAction { fullWindowAction() } else { fullScreenRevision &+= 1 } }
        #else
        if present { fullScreenRevision &+= 1 }
        selectedChannel = channel
        #endif
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
            channelIndex: channelIndex,
            categories: channelSnapshot.categories,
            selectedCategory: $selectedCategory,
            guide: guideStore.guide(for: playbackGuideChannelIDs),
            guideRevision: guideStore.revision,
            entries: completeGuide,
            favoriteIDs: settings.favoriteChannelIDs,
            favoriteOrder: selectedCategory == "Favorites" ? settings.favoriteLiveChannelOrder : [],
            nowPlaying: selectedChannel ?? lastWatchedChannel ?? channels.first,
            hasActiveSearch: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            previewsEnabled: AppleTVPictureInPicturePolicy.previewsEnabled(
                preference: settings.autoPlayTrailer, isPictureInPictureActive: pictureInPicture.isActive),
            isPlayerOpen: tvPlayer != nil,
            focusRestoreToken: tvFocusRestore,
            focusRestoreChannelID: selectedChannel?.id ?? lastWatchedChannelID,
            searchDestination: { AppleTVChannelSearchEditor(query: $query) },
            onSelect: play,
            onToggleFavorite: toggleFavorite,
            onVisibleChannels: refreshGuide,
            health: channelHealth,
            healthRevision: channelHealthRevision,
            onShowHealth: { healthDetailChannel = $0 },
            onMultiview: AppleTVPictureInPicturePolicy.offersMultiview(
                isPictureInPictureActive: pictureInPicture.isActive) ? { beginMultiview(held: $0) } : nil,
            onSelectProgramme: playProgramme
        )
        // The tab root draws no page title on a television; the tab bar names it.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $tvPlayer, onDismiss: {
            appleTrace("live production cover dismissed")
            tvFocusRestore &+= 1
        }) { _ in
            if !tvMultiviewChannels.isEmpty {
                AppleTVMultiviewScreen(initial: tvMultiviewChannels, channels: channelSnapshot.channels,
                    guide: guideStore.guide(for: playbackGuideChannelIDs), onExit: { channel in
                        tvMultiviewChannels = []
                        startChannel(channel, shareSelection: true)
                    })
                    .task(id: AppleLiveSystemChannels.shared.requestedChannelID) { consumeLiveChannelRequest() }
            } else if let channel = selectedChannel {
                AppleTVLivePlayerScreen(
                    channel: channel,
                    coordinator: playbackCoordinator,
                    footerChannels: channelSnapshot.channels,
                    footer: $tvFooter,
                    alternateLineup: channels,
                    sourceNames: liveSourceNames,
                    guide: guideStore.guide(for: playbackGuideChannelIDs),
                    programme: catchUp,
                    channelNumber: lineupIndex.match(channel.name)?.number ?? channel.channelNumber,
                    playbackRevision: playbackRevision,
                    onStartOver: startOverAction,
                    onLastChannel: lastChannelAction,
                    onMultiview: { beginMultiview(held: $0) },
                    allowsPictureInPicture: true,
                    liveSession: liveSession,
                    onSwitch: { startChannel($0, shareSelection: true) }
                )
                .modifier(ApplePINPresenter())
                .safeAreaInset(edge: .bottom) { AppleImportProgressView() }
                .id(ObjectIdentifier(playbackCoordinator))
                .task(id: AppleLiveSystemChannels.shared.requestedChannelID) { consumeLiveChannelRequest() }
                // A full-screen cover can suspend the underlying view's task.
                // Footer channel switches and their errors belong to this
                // visible surface; the root is gated off while it is presented.
                .task(id: pendingProbe?.id) {
                    guard probeSurfaceIsActive(isPlayer: true) else { return }
                    await probePendingChannel()
                }
                .alert("Channel Unavailable", isPresented: probeFailureBinding(isPlayer: true)) {
                    probeFailureActions
                } message: {
                    Text(probeFailureMessage ?? "")
                }
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

    private func beginMultiview(held: AppleIPTVChannel?) {
        guard AppleTVPictureInPicturePolicy.offersMultiview(isPictureInPictureActive: pictureInPicture.isActive) else { return }
        let current = selectedChannel ?? lastWatchedChannel ?? channelSnapshot.channels.first
        guard let current else { return }
        guard let otherID = AppleMultiviewPolicy.companionID(currentID: current.id,
            heldID: held?.id, orderedIDs: channelSnapshot.channelIDs),
              let other = held?.id == otherID ? held : channelSnapshot.channels.first(where: { $0.id == otherID }) else { return }
        guard AppleTVMultiviewSession.thermal != .serious && AppleTVMultiviewSession.thermal != .critical else {
            probeFailureMessage = AppleMultiviewPolicy.Refusal.thermal.message
            return
        }
        playbackCoordinator.stop()
        pendingProbe = nil
        catchUp = nil
        tvMultiviewChannels = [current, other]
        if tvPlayer == nil { tvPlayer = AppleTVLivePlayerPresentation() }
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

    #if os(iOS) || os(visionOS)
    /// iPhone and iPad Live (owner items 7–10): the video edge to edge under
    /// the status bar, the category row fixed under it, the channel list the
    /// only thing that scrolls. One `AnyLayout` stacks the two columns on
    /// iPhone and iPad and sets them side by side on a Duo on its side or a
    /// wide visionOS window; the same child views keep their identity across
    /// the switch, so the channel never reloads on rotation or resize.
    private var liveStage: some View {
        #if os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        #else
        let isPad = false
        #endif
        let sideBySide = AppleLiveStagePolicy.sideBySide(
            isRegularWidth: horizontalSizeClass == .regular, size: viewportSize,
            expandsPhoneLayout: expandsPhoneLayout, isPad: isPad)
        let layout = sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            liveStagePlayerColumn(sideBySide: sideBySide, showsSchedule: AppleLiveStagePolicy.showsSchedule(
                sideBySide: sideBySide, expandsPhoneLayout: expandsPhoneLayout))
                .frame(width: sideBySide ? AppleLiveStagePolicy.playerWidth(total: viewportSize.width) : nil)
                .frame(maxHeight: sideBySide ? .infinity : nil, alignment: .top)
                #if os(iOS)
                // Stacked, edge to edge: the video fills the side column, and its slot is as
                // tall as that width needs; the rows below stay beside the column.
                .frame(height: sideBySide || stageSideInsets == EdgeInsets() ? nil : stackedStageHeight)
                .ignoresSafeArea(.container, edges: sideBySide ? [] : stageBleedEdges)
                #endif
                // Stacked, the stage takes its full height first; the list gets the rest.
                .layoutPriority(1)
            liveStageGuideColumn
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                        .opacity(sideBySide ? 1 : 0)
                }
        }
        .background(Color.black)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { viewportSize = $0 }
        #if os(iOS)
        .onGeometryChange(for: EdgeInsets.self, of: AppleHeroSideBleed.sides) { stageSideInsets = $0 }
        #endif
        .onChange(of: liveCategoryTabs) { _, tabs in
            // The last favourite removed or the events gone: back to All.
            let resolved = AppleLiveCategoryOrder.resolved(selectedCategory, in: tabs)
            if resolved != selectedCategory { selectedCategory = resolved }
        }
        .sheet(isPresented: $showsGuide) { liveGuideSheet }
    }

    private var usesPhoneLiveLayout: Bool {
        #if os(iOS)
        !isLargeLayout
        #else
        false
        #endif
    }

    /// iPhone, iPad and Duo share the Paramount+ strip and rows (owner 2026-10-21).
    private var usesParamountLiveStyle: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The stage's shape: 16:9, or as wide as the window and shorter when a
    /// large window stacks with too little room left for the rows.
    private func stageAspectRatio(sideBySide: Bool) -> CGFloat {
        guard usesParamountLiveStyle, !usesPhoneLiveLayout, !sideBySide else { return 16 / 9 }
        let height = AppleLiveStagePolicy.stackedStageHeight(size: viewportSize)
        return height > 0 ? stackedStageWidth / height : 16 / 9
    }

    #if os(iOS)
    private var stageBleedEdges: Edge.Set {
        var edges: Edge.Set = []
        if stageSideInsets.leading > 0 { edges.insert(.leading) }
        if stageSideInsets.trailing > 0 { edges.insert(.trailing) }
        return edges
    }
    #endif

    /// Stacked, the stage spans the side column too.
    private var stackedStageWidth: CGFloat {
        viewportSize.width + stageSideInsets.leading + stageSideInsets.trailing
    }

    private var stackedStageHeight: CGFloat? {
        stackedStageWidth > 0 ? stackedStageWidth / stageAspectRatio(sideBySide: false) : nil
    }

    private var liveGuideSheet: some View {
        NavigationStack {
            AppleIPTVGuideGridView(channels: channelSnapshot.channels,
                guide: guideStore.guide(for: playbackGuideChannelIDs), guideRevision: guideStore.revision,
                entries: completeGuide, favoriteIDs: settings.favoriteChannelIDs,
                onSelect: { channel in
                    showsGuide = false
                    if channel.id != selectedChannel?.id || catchUp != nil {
                        startChannel(channel, shareSelection: true, present: false)
                    }
                }, onToggleFavorite: toggleFavorite, onVisibleChannels: refreshGuide,
                health: channelHealth, onShowHealth: { healthDetailChannel = $0 },
                onSelectProgramme: { channel, programme in
                    showsGuide = false
                    startChannel(channel, shareSelection: false, present: false, programme: programme)
                }, compactPhoneLayout: usesPhoneLiveLayout)
                // The grid's scroll views reach under the inline bar, so rows drew above the pinned
                // time bar behind "Guide" (owner recording 2026-10-15, 7:20). Clip them to the grid.
                .clipped()
                .background(Color.black)
                .navigationTitle("Guide")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showsGuide = false }
                            .accessibilityIdentifier("live.guide.done")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func liveStagePlayerColumn(sideBySide: Bool, showsSchedule: Bool) -> some View {
        let programme = selectedChannel.flatMap {
            guideStore.guide(for: [$0.id]).nowAndNext(channelID: $0.id).now
        }
        return VStack(spacing: 0) {
            Group {
                if let selectedChannel, !fullWindowHoldsChannel {
                    stageInlinePlayer(selectedChannel)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Live player for \(selectedChannel.displayName)")
                        .accessibilityValue(playbackCoordinator.phase == .playing ? "Playing"
                            : (playbackCoordinator.phase.isBusy ? "Loading" : ""))
                } else {
                    // Black until a channel is chosen (owner 2026-10-22): the list says it is loading.
                    Color.black
                        .accessibilityLabel(channels.isEmpty ? "No channels" : "Connecting to live channel")
                        .accessibilityHidden(showsChannelsLoading)
                }
            }
            .aspectRatio(stageAspectRatio(sideBySide: sideBySide), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            // The schedule under it takes what is left, never the stage's 16:9.
            .layoutPriority(1)
            .accessibilityIdentifier("live.stage.player")
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .overlay {
                let kind = UserDefaults.standard.string(forKey: "OpenStreamLiveHitTestOverlay")
                if UserDefaults.standard.bool(forKey: "OpenStreamProbeLiveHitTest") || kind == "other" || kind == "image" {
                    AppleDebugLiveHitTestOverlay()
                        .allowsHitTesting(kind == "other" || kind == "image")
                }
            }
            #endif
            if sideBySide || !usesParamountLiveStyle {
                AppleLiveProgrammeLine(programme: programme)
            }
            #if os(iOS)
            if showsSchedule {
                AppleLiveStageSchedule(channelName: selectedChannel?.displayName, channelID: selectedChannel?.id,
                                       guide: guideStore.guide(for: selectedChannel.map { [$0.id] } ?? []))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            #endif
        }
    }

    private func stageInlinePlayer(_ channel: AppleIPTVChannel) -> some View {
        AppleLiveInlinePlayer(
            request: playbackRequest(for: channel),
            coordinator: playbackCoordinator,
            playbackRevision: playbackRevision,
            fullScreenRevision: fullScreenRevision,
            logoURL: channel.logoURL,
            sharedChannel: try? AppleSharePlayChannel(channel: channel),
            sharePlay: sharePlay,
            liveChannel: channel,
            channels: channelSnapshot.channels,
            otherListLineup: channelIndex,
            sourceNames: liveSourceNames,
            guide: guideStore.guide(for: playbackGuideChannelIDs),
            onSwitchChannel: { startChannel($0, shareSelection: true, present: false) },
            onLastChannel: lastChannelAction,
            onStartOver: startOverAction,
            onRequestFullWindow: fullWindowAction,
            onCloseFullScreen: fullScreenPlayerClosed,
            isConnecting: pendingProbe != nil,
            onOpenSettings: openSettings,
            isSearching: $showsSearch,
            isActive: isActive
        )
        .id(ObjectIdentifier(playbackCoordinator))
    }

    private var liveStageGuideColumn: some View {
        VStack(spacing: 0) {
            if showsChannelsLoading {
                AppleLiveChannelsLoading()
                    .background(usesParamountLiveStyle ? AppleLiveStagePolicy.phonePanel : .black)
            } else {
                AppleLiveCategoryBar(tabs: liveCategoryTabs, selection: Binding(
                    get: { AppleLiveCategoryOrder.resolved(selectedCategory, in: liveCategoryTabs) },
                    set: { selectedCategory = $0 }
                ), onSearch: { showsSearch = true }, onGuide: { showsGuide = true },
                    usesParamountStyle: usesParamountLiveStyle)
                liveOnNowList(channels: channelSnapshot.channels)
            }
        }
    }

    private func liveOnNowList(channels list: [AppleIPTVChannel], showsSourceProblems: Bool = true) -> some View {
        AppleLiveOnNowList(
            channels: list,
            guide: guideStore.guide(for: playbackGuideChannelIDs),
            guideRevision: guideStore.revision,
            currentChannelID: pendingProbe?.channel.id ?? selectedChannel?.id,
            favoriteIDs: settings.favoriteChannelIDs,
            hiddenCount: showsSourceProblems ? channelSnapshot.hiddenCount : 0,
            showsEmptyText: snapshotRevision > 0 && hasResolvedFirstLoad,
            sourceProblems: showsSourceProblems ? liveSourceProblems : [],
            usesParamountStyle: usesParamountLiveStyle,
            onSelect: playFromList,
            onToggleFavorite: toggleFavorite,
            onHide: { settings.hiddenLiveChannelIDs.insert($0.id) },
            onShowInfo: { healthDetailChannel = $0 },
            onRetrySources: { Task { await reload() } },
            onVisibleChannels: refreshGuide
        )
    }

    private var liveSourceProblems: [AppleLiveOnNowList.SourceProblem] {
        sourceFailures.filter { !$0.showsSavedChannels }.map {
            AppleLiveOnNowList.SourceProblem(id: $0.id,
                title: sourceCauses[$0.id]?.title ?? AppleLiveFailureCause.loadFailed(source: $0.sourceName).title)
        }
    }

    private func playFromList(_ channel: AppleIPTVChannel) {
        let wasSearching = showsSearch
        dismissLiveSearch()
        if channel.id == selectedChannel?.id, catchUp == nil, pendingProbe == nil {
            guard !(wasSearching && usesParamountLiveStyle), !usesPhoneLiveLayout else { return }
            AppleInteractionTrace.record(.press, "live row full screen \(channel.name)")
            #if os(visionOS)
            if let fullWindowAction { fullWindowAction() } else { fullScreenRevision &+= 1 }
            #else
            fullScreenRevision &+= 1
            #endif
            return
        }
        AppleInteractionTrace.record(.press, "live row \(channel.name)")
        startChannel(channel, shareSelection: true, present: false)
    }

    private var liveCategoryTabs: [String] {
        AppleLiveCategoryOrder.tabs(groups: channelSnapshot.categories,
            hasFavorites: !settings.favoriteChannelIDs.isEmpty, eventCount: eventChannelCount)
    }
    #endif

    @ViewBuilder
    private var lastWatchedCard: some View {
        #if os(iOS)
        AppleLiveConnectingArtwork(logoURL: lastWatchedChannel?.logoURL ?? channels.first?.logoURL)
            .livePinnedPlayerLayout(isPlaceholder: true, viewportSize: viewportSize, verticalSizeClass: verticalSizeClass)
        #else
        AppleLiveConnectingArtwork(logoURL: lastWatchedChannel?.logoURL ?? channels.first?.logoURL)
            .livePinnedPlayerLayout(isPlaceholder: true)
        #endif
    }

    private var lastWatchedChannel: AppleIPTVChannel? {
        guard !lastWatchedChannelID.isEmpty else { return nil }
        return channelIndex[lastWatchedChannelID]
    }

    private func toggleFavorite(_ id: String) {
        settings.favoriteChannelIDs = AppleTVGuideRailCellModel.togglingFavorite(id, in: settings.favoriteChannelIDs)
    }

}

private struct LivePinnedPlayerLayout: ViewModifier {
    let isPlaceholder: Bool
    #if os(iOS)
    let viewportSize: CGSize?
    let verticalSizeClass: UserInterfaceSizeClass?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad && verticalSizeClass == .compact, let viewportSize = viewportSize {
            content
                .aspectRatio(16 / 9, contentMode: .fit)
                
                .frame(width: viewportSize.width, height: viewportSize.height)
                .background(Color.black)
                .ignoresSafeArea(.container, edges: .all)
        } else {
            let base = content
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .horizontal)
                
            if isPlaceholder && isPad {
                base.containerRelativeFrame(.vertical, count: 100, span: 40, spacing: 0, alignment: .center)
            } else {
                base
            }
        }
        #else
        content
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
        #endif
    }
}

private extension View {
    #if os(iOS)
    func livePinnedPlayerLayout(isPlaceholder: Bool = false, viewportSize: CGSize? = nil, verticalSizeClass: UserInterfaceSizeClass? = nil) -> some View { 
        modifier(LivePinnedPlayerLayout(isPlaceholder: isPlaceholder, viewportSize: viewportSize, verticalSizeClass: verticalSizeClass)) 
    }
    #else
    func livePinnedPlayerLayout(isPlaceholder: Bool = false) -> some View { modifier(LivePinnedPlayerLayout(isPlaceholder: isPlaceholder)) }
    #endif
}

/// Inline Live-tab playback surface. The coordinator and AVKit host stay owned
/// by the tab so channel changes reload the same engine without presenting a
/// second player. AVKit owns transport controls and its full-screen affordance.
@MainActor
struct AppleLiveInlinePlayer: View {
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var isSearching: Bool
    @State private var suspendedRequestID: String?
    @State private var suspendedPosition: Double?
    @State private var suspendedWasPlaying: Bool?
    @State private var isFullScreen = false
    @State private var lifetime = AppleLivePlaybackLifetime()
    @State private var startup = ApplePlaybackStartup(starting: true)
    @State private var inlineSubtitles = AppleStockPlayerSubtitles()

    let request: ApplePlaybackRequest
    let coordinator: ApplePlaybackCoordinator
    let playbackRevision: Int
    let fullScreenRevision: Int
    let logoURL: URL?
    let sharedChannel: AppleSharePlayChannel?
    let sharePlay: AppleSharePlaySessionStore
    let liveChannel: AppleIPTVChannel?
    let channels: [AppleIPTVChannel]
    /// Every list's channels, searched for this channel on another list
    /// when it cannot be recovered ("Watch on <list>").
    let otherListLineup: AppleIPTVChannelIndex
    let sourceNames: [UUID: String]
    let guide: AppleIPTVGuide
    let onSwitchChannel: ((AppleIPTVChannel) -> Void)?
    let onLastChannel: (() -> Void)?
    let onStartOver: (() -> Void)?
    /// macOS and visionOS: the channel goes to the window's full player
    /// (`AppleMacPlayerStage`, `AppleVisionPlayerStage`), the same one every
    /// other title plays in.
    let onRequestFullWindow: (() -> Void)?
    let onCloseFullScreen: (() -> Void)?
    /// The Live tab is checking a channel's stream before it starts: the
    /// frame shows the spinner, not a "Connecting to…" line.
    let isConnecting: Bool
    let isActive: Bool
    /// Login failures send the viewer to Settings.
    let onOpenSettings: (() -> Void)?
    #if os(macOS)
    @State private var fullWindowButtonVisible = true
    @State private var pointerActivity = 0
    private let macCommands = AppleMacCommandCenter.shared
    #endif

    init(request: ApplePlaybackRequest, coordinator: ApplePlaybackCoordinator, playbackRevision: Int, fullScreenRevision: Int = 0, logoURL: URL?, sharedChannel: AppleSharePlayChannel?, sharePlay: AppleSharePlaySessionStore = .shared, liveChannel: AppleIPTVChannel? = nil, channels: [AppleIPTVChannel] = [], otherListLineup: AppleIPTVChannelIndex = AppleIPTVChannelIndex([]), sourceNames: [UUID: String] = [:], guide: AppleIPTVGuide = AppleIPTVGuide(programmes: []), onSwitchChannel: ((AppleIPTVChannel) -> Void)? = nil, onLastChannel: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil, onRequestFullWindow: (() -> Void)? = nil, onCloseFullScreen: (() -> Void)? = nil, isConnecting: Bool = false, onOpenSettings: (() -> Void)? = nil, isSearching: Binding<Bool> = .constant(false), isActive: Bool = true) {
        _isSearching = isSearching
        self.isActive = isActive
        self.onRequestFullWindow = onRequestFullWindow
        self.onCloseFullScreen = onCloseFullScreen
        self.isConnecting = isConnecting
        self.onOpenSettings = onOpenSettings
        self.request = request
        self.coordinator = coordinator
        self.playbackRevision = playbackRevision
        self.fullScreenRevision = fullScreenRevision
        self.logoURL = logoURL
        self.sharedChannel = sharedChannel
        self.sharePlay = sharePlay
        self.liveChannel = liveChannel
        self.channels = channels
        self.otherListLineup = otherListLineup
        self.sourceNames = sourceNames
        self.guide = guide
        self.onSwitchChannel = onSwitchChannel
        self.onLastChannel = onLastChannel
        self.onStartOver = onStartOver
    }

    var body: some View {
        ZStack {
            if let resources = lifetime.resources(for: coordinator) {
                player(host: resources.host, audioSession: resources.audioSession)
            } else {
                Color.black
            }
        }
        .onChange(of: ObjectIdentifier(coordinator), initial: true) { lifetime.configure(for: coordinator) }
        .onChange(of: isActive) { _, active in
            if !active, isSearching, let resources = lifetime.resources(for: coordinator) {
                lifetime.inlineDisappeared(host: resources.host, coordinator: coordinator)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isSearching, let resources = lifetime.resources(for: coordinator) {
                lifetime.enteredBackground(host: resources.host, coordinator: coordinator)
            }
        }
        .onDisappear {
            if let resources = lifetime.resources(for: coordinator) {
                lifetime.inlineDisappeared(host: resources.host, coordinator: coordinator, isSearching: isSearching && isActive)
            }
        }
    }

    @ViewBuilder
    private func player(host: ApplePlayerHost, audioSession: AppleAudioSessionCoordinator) -> some View {
        let _ = AppleLiveWatchHistoryStore.shared.history
        ZStack {
            #if os(macOS)
            if coordinator.route == .surface {
                ApplePlaybackSurfaceView(engine: coordinator.engine)
                // Its full-screen button used to hide the surface and show
                // nothing in its place: a black pane. It opens the full player.
                AppleTransportOverlay(coordinator: coordinator, request: request,
                    onRequestFullScreen: onRequestFullWindow, sharePlayMenu: sharePlayMenu,
                    showsWaitingIndicator: false)
            } else {
                AppleMacPlayerViewRepresentable(
                    playerView: host.playerView,
                    zoomToFill: macCommands.zoomToFill,
                    showsAVKitFullScreenButton: onRequestFullWindow == nil,
                    subtitleEntries: inlineSubtitles.menuEntries,
                    moreSubtitleEntries: inlineSubtitles.moreEntries,
                    showsSubtitleMenu: AppleStockSubtitleMenuPolicy.showsAppMenu(
                        tracks: coordinator.engine.subtitleTracks,
                        stockPlayerListsCaptions: inlineSubtitles.stockPlayerListsCaptions),
                    onSelectSubtitle: { id in
                        host.selectSubtitleTrack(id: id)
                        inlineSubtitles.refresh(from: coordinator.engine)
                    }
                )
                .opacity(startup.coversPicture(phase: coordinator.phase) ? 0 : 1)
                .accessibilityHidden(showsConnectingOverlay)
                if AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(
                    engine: coordinator.engine.kind, route: coordinator.route) {
                    AppleLiveInlineCueLayer(engine: coordinator.engine, subtitles: inlineSubtitles)
                }
                if let onRequestFullWindow, fullWindowButtonVisible {
                    AppleLiveFullWindowButton(action: onRequestFullWindow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
            #else
            // Keep the container mounted across native/surface route changes.
            // Its over-full-screen presentation keeps the guide's load/probe tasks alive.
            AppleLivePlayerControllerRepresentable(
                viewController: host.viewController,
                coordinator: coordinator,
                request: request,
                fullScreenRevision: fullScreenRevision,
                liveMenu: sharePlayMenu,
                channels: channels,
                guide: guide,
                currentChannelID: liveChannel?.id,
                onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver,
                onFullScreenChanged: {
                    if lifetime.isFullScreen && !$0 && !host.keepsPlaybackForPictureInPicture {
                        onCloseFullScreen?()
                    }
                    lifetime.isFullScreen = $0
                    isFullScreen = $0
                },
                onRequestFullWindow: onRequestFullWindow,
                isBusy: showsConnectingOverlay, keepsPicture: startup.hasPresentedFrame,
                failureContext: AppleLiveFailureContext(sourceNames: sourceNames, onOpenSettings: onOpenSettings)
            )
            #endif
            if showsConnectingOverlay {
                if startup.coversPicture(phase: coordinator.phase) {
                    AppleLiveConnectingArtwork(logoURL: logoURL).allowsHitTesting(false)
                }
                AppleLiveTuningDelay(id: liveChannel?.id ?? "", immediate: showsReconnecting) {
                    VStack(spacing: 8) {
                        ApplePlaybackLoadingIndicator(label: showsReconnecting ? "Reconnecting" : "Loading")
                            .accessibilityIdentifier("live.loading")
                        if showsReconnecting {
                            Text("Reconnecting…")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(showsReconnecting ? "live.reconnecting" : "live.connecting")
                    .allowsHitTesting(false)
                }
            }
            if !isFullScreen, case .failed(let failure) = coordinator.phase,
               AppleLiveFailurePresentation.isVisible(failure) {
                failureCard(failure)
            } else if let liveChannel, request.isLive {
                #if !os(macOS)
                channelBadge(liveChannel)
                #endif
            }
        }
        .background(.black)
        .modifier(AppleLiveWatchTracking(channelID: liveChannel?.id, coordinator: coordinator,
            revision: playbackRevision, isLive: request.isLive))
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { pointerActivity &+= 1 }
        }
        .simultaneousGesture(TapGesture().onEnded { pointerActivity &+= 1 })
        .task(id: "\(pointerActivity):\(coordinator.phase)") {
            withAnimation(.easeOut(duration: 0.2)) { fullWindowButtonVisible = true }
            guard case .playing = coordinator.phase else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { fullWindowButtonVisible = false }
        }
        #endif
        .onChange(of: isFullScreen) { _, isFullScreen in
            #if !os(macOS)
            host.viewController.requiresLinearPlayback = !isFullScreen
            host.viewController.allowsPictureInPicturePlayback = isFullScreen
            #endif
        }
        .modifier(AppleSleepTimerPresentation(coordinator: coordinator, enabled: !isFullScreen))
        .onChange(of: guide.nowAndNext(channelID: liveChannel?.id ?? "").now?.end, initial: true) { _, end in
            coordinator.sleepProgrammeEnd = end
        }
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
                lifetime.enteredBackground(host: host, coordinator: coordinator)
                return
            }
            lifetime.enteredForeground()
            // SwiftUI can restart this task when a full-screen cover returns.
            // Only a new channel/retry or a real stop needs a new player item.
            guard lifetime.beginLoad(identity: "\(requestIdentity):\(playbackRevision)") else { return }
            startup.begin(UUID())
            startup.handOff()
            coordinator.stop()
            host.observeStartup(startup)
            host.activate()
            host.configureLivePlaybackControls()
            #if os(macOS)
            // AVPlayerView's own CC menu, the same as the full player's.
            host.enableSubtitleSelectionMirroring()
            #endif
            #if !os(macOS)
            host.viewController.requiresLinearPlayback = !lifetime.isFullScreen
            host.viewController.allowsPictureInPicturePlayback = lifetime.isFullScreen
            #endif
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
            let alternates = await AppleLiveChannelAlternates.playbackCandidates(
                for: liveChannel, request: playbackRequest, in: otherListLineup.channels,
                recentlyFailed: ApplePlaybackFailureHistory.shared.recentURLs())
            guard !Task.isCancelled else { return }
            await coordinator.begin(playbackRequest, fallbackCandidates: alternates)
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase.isBusy, startup.phase == .timedOut {
                startup.handOff()
                host.observeStartup(startup)
            }
            refreshStartup()
        }
        .task(id: startup.phase) {
            guard startup.isLoading else { return }
            if await startup.waitForTimeout(for: startup.requestID) {
                coordinator.fail(URLError(.timedOut))
                coordinator.engine.stop()
            }
        }
        // Full screen only: the inline picture says it in place
        // (`failureCard`), so the guide under it stays usable.
        .alert(failureTitle, isPresented: failureBinding) {
            if let other = otherListChannel, let onSwitchChannel {
                Button(AppleLiveOtherListMatch.offerTitle(sourceName: sourceNames[other.sourceID])) {
                    appleTrace("live other-list chosen: \(AppleLiveOtherListMatch.offerTitle(sourceName: sourceNames[other.sourceID]))")
                    onSwitchChannel(other)
                }
            }
            Button(retryTitle) {
                if case .failed(let failure) = coordinator.phase { retryOrSwitch(after: failure) }
            }
            Button("Close", role: .cancel) { coordinator.stop() }
        } message: {
            if let failureDetail { Text(failureDetail) }
        }
    }

    private func refreshStartup() {
        startup.observe(coordinator.phase, route: coordinator.route,
                        readyForDisplay: lifetime.resources(for: coordinator)?.host.isReadyForDisplay == true,
                        for: startup.requestID)
        if !startup.isLoading { lifetime.resources(for: coordinator)?.host.stopStartupObservation() }
    }

    private var showsReconnecting: Bool {
        startup.showsReconnecting(coordinator.isReconnectingLive)
    }

    private var showsConnectingOverlay: Bool {
        startup.isLoading || coordinator.phase.isBusy || isConnecting
    }

    /// A channel that will not play, said inside the picture: one line naming
    /// the channel, one naming who did not answer, Try Again — the Apple TV
    /// player's wording (`AppleLiveFailurePresentation`). It replaces a
    /// "Playback Failed" alert that opened by itself over the whole Live tab
    /// whenever the resumed channel could not be reached, with a paragraph of
    /// advice in it (owner 2026-10-08: "looks off and weird").
    @ViewBuilder
    private func failureCard(_ failure: ApplePlaybackFailure) -> some View {
        #if os(iOS)
        if request.isLive, let cause = AppleLiveFailureCause.playback(failure, channelName: liveChannel?.displayName,
            sourceName: liveChannel.flatMap { sourceNames[$0.sourceID] }) {
            AppleLiveFailureCard(cause: cause) { performFailureAction(cause.action) }
                .background(.black)
        } else {
            legacyFailureCard(failure)
        }
        #else
        legacyFailureCard(failure)
        #endif
    }

    #if os(iOS)
    private func performFailureAction(_ action: AppleLiveFailureCause.Action) {
        switch action {
        case .nextChannel:
            switchToNextChannel()
        case .openSettings, .addSource:
            if let onOpenSettings { onOpenSettings() } else { Task { await coordinator.retry() } }
        case .tryAgain:
            Task { await coordinator.retry() }
        }
    }
    #endif

    private func switchToNextChannel() {
        if let liveChannel, let onSwitchChannel,
           let id = AppleLiveZappingPolicy.target(currentID: liveChannel.id,
               orderedIDs: channels.map(\.id), direction: .next),
           let next = channels.first(where: { $0.id == id }) {
            onSwitchChannel(next)
        } else {
            Task { await coordinator.retry() }
        }
    }

    /// A channel the provider refuses fails the same way on every retry.
    private func retryOrSwitch(after failure: ApplePlaybackFailure) {
        if request.isLive, AppleLiveFailurePresentation.isChannelRefusal(failure) { switchToNextChannel() }
        else { Task { await coordinator.retry() } }
    }

    private func legacyFailureCard(_ failure: ApplePlaybackFailure) -> some View {
        VStack(spacing: 12) {
            Text(request.isLive
                 ? AppleLiveFailurePresentation.message(for: failure, channelName: liveChannel?.displayName)
                 : "Playback Failed")
                .font(AppleDesignTokens.fontHeadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let failureDetail {
                Text(failureDetail)
                    .font(AppleDesignTokens.fontCaption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                if let other = otherListChannel, let onSwitchChannel {
                    let title = AppleLiveOtherListMatch.offerTitle(sourceName: sourceNames[other.sourceID])
                    Button(title) {
                        appleTrace("live other-list chosen: \(title)")
                        onSwitchChannel(other)
                    }
                    .buttonStyle(.brandSecondary)
                    .accessibilityIdentifier("live.failure.otherList")
                }
                Button(AppleLiveFailurePresentation.retryTitle(for: failure)) { retryOrSwitch(after: failure) }
                    .buttonStyle(.brandPrimary)
                    .accessibilityIdentifier("live.failure.retry")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.failure")
    }

    /// The channel's logo over the video, top-left, always on (not part of
    /// the auto-hiding chrome): the first thing the owner missed was which
    /// channel is on (item 7). The name stands in when there is no logo.
    private func channelBadge(_ channel: AppleIPTVChannel) -> some View {
        AppleLiveLogoMark(url: channel.logoURL, height: 20, maxWidth: 80,
                          channelName: channel.displayName, fallbackText: channel.displayName, alignment: .leading)
            .shadow(color: .black.opacity(0.4), radius: 2)
            // The element is the logo's own size: a full-frame element hid the
            // player's buttons from VoiceOver and XCTest hit points.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(channel.displayName), now playing")
            .accessibilityIdentifier("live.channelBadge")
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    private var failureTitle: String {
        guard case .failed(let failure) = coordinator.phase else { return "" }
        guard request.isLive else { return "Playback Failed" }
        return AppleLiveFailurePresentation.message(for: failure, channelName: liveChannel?.displayName)
    }

    private var retryTitle: String {
        guard case .failed(let failure) = coordinator.phase else { return "Try Again" }
        return AppleLiveFailurePresentation.retryTitle(for: failure)
    }

    /// The quieter line: the host that did not answer, or nothing.
    private var failureDetail: String? {
        guard case .failed(let failure) = coordinator.phase else { return nil }
        guard request.isLive else { return failure.userMessage }
        return AppleLiveFailurePresentation.detail(for: failure, endpoint: request.url.host())
    }

    private var requestIdentity: String {
        "\(request.mediaID)|\(request.url.absoluteString)"
    }

    /// This channel on another list, while it is failed.
    private var otherListChannel: AppleIPTVChannel? {
        guard request.isLive, let liveChannel, case .failed(let failure) = coordinator.phase,
              failure.kind != .cancelled,
              failure.kind != .authentication || AppleLiveFailurePresentation.isChannelRefusal(failure) else { return nil }
        return AppleLiveOtherListMatch.match(
            for: liveChannel, in: otherListLineup.channels,
            excludingURLs: Set(coordinator.triedSourceURLs),
            hasRecentlyFailed: { ApplePlaybackFailureHistory.shared.contains($0) })
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                #if os(iOS)
                // iPhone and iPad Live say it in the full-screen card instead.
                if request.isLive { return false }
                #endif
                if isFullScreen, case .failed(let failure) = coordinator.phase { return failure.kind != .cancelled }
                return false
            },
            set: { if !$0, isFullScreen, case .failed = coordinator.phase { coordinator.reset() } }
        )
    }

    #if os(macOS)
    private var sharePlayMenu: AppleTransportOverlay.SharePlayMenu? { nil }
    #else
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
/// Live's way to the full player on the AVKit route, whose floating controls
/// no longer carry AVKit's own full-screen button. The same glyph and ring as
/// the transport overlay's, in the same corner.
private struct AppleLiveFullWindowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(ApplePlayerControlMetrics.chromeFont)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appleHoverAffordance()
        .padding()
        .accessibilityLabel("Full Screen")
        .accessibilityIdentifier("player.fullscreen")
    }
}
#else
private struct AppleLivePlayerControllerRepresentable: UIViewControllerRepresentable {
    let viewController: AVPlayerViewController
    let coordinator: ApplePlaybackCoordinator
    let request: ApplePlaybackRequest
    let fullScreenRevision: Int
    let liveMenu: AppleTransportOverlay.SharePlayMenu?
    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    let currentChannelID: String?
    let onSwitchChannel: ((AppleIPTVChannel) -> Void)?
    let onLastChannel: (() -> Void)?
    let onStartOver: (() -> Void)?
    let onFullScreenChanged: (Bool) -> Void
    /// visionOS: the full-screen button opens the window's player instead
    /// of AVKit's modal. Nil on iOS.
    var onRequestFullWindow: (() -> Void)? = nil
    var isBusy = false
    var keepsPicture = false
    var failureContext = AppleLiveFailureContext()

    func makeUIViewController(context: Context) -> AppleLivePlayerContainerViewController {
        let vc = AppleLivePlayerContainerViewController(playerViewController: viewController,
            coordinator: coordinator, request: request, liveMenu: liveMenu,
            channels: channels, guide: guide, currentChannelID: currentChannelID,
            onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver,
            onFullScreenChanged: onFullScreenChanged)
        vc.onRequestFullWindow = onRequestFullWindow
        vc.failureContext = failureContext
        return vc
    }

    func updateUIViewController(_ vc: AppleLivePlayerContainerViewController, context: Context) {
        vc.onRequestFullWindow = onRequestFullWindow
        vc.failureContext = failureContext
        vc.update(request: request, liveMenu: liveMenu, channels: channels,
                  guide: guide, currentChannelID: currentChannelID,
                  onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver, fullScreenRevision: fullScreenRevision)
        vc.setBusy(isBusy, keepsPicture: keepsPicture)
        vc.attachPlayerIfNeeded()
    }
}
#endif

#if !os(macOS)
/// AVKit still renders native video and legible tracks underneath this view.
/// The same chrome and picker stay mounted when a channel changes its route.
private struct AppleLiveFullScreenControls: View {
    let coordinator: ApplePlaybackCoordinator
    let request: ApplePlaybackRequest
    let sharePlayMenu: AppleTransportOverlay.SharePlayMenu?
    let channels: [AppleIPTVChannel]
    /// What is on each channel now. The Live tab has already loaded it; the
    /// picker only reads it.
    let guide: AppleIPTVGuide
    let currentChannelID: String?
    let onSwitchChannel: ((AppleIPTVChannel) -> Void)?
    let onLastChannel: (() -> Void)?
    let onStartOver: (() -> Void)?
    let onClose: () -> Void
    let channelPicker: AppleLiveChannelPickerState
    var failureContext = AppleLiveFailureContext()
    @State private var hideChromeSignal = false
    /// A channel swipe is under way: the video-area tap must not open the list.
    @State private var swipeInProgress = false
    /// When the channel last changed, from any gesture or control. On iPhone
    /// the swipe is a UIKit recogniser on the video container, so it never
    /// reaches the SwiftUI drag above; the switch itself is the one signal
    /// every path shares.
    @State private var lastChannelSwitch: ContinuousClock.Instant?
    @State private var pickerShowTask: Task<Void, Never>?
    #if os(iOS)
    /// Seeded from the window so the first body already picks the right picker.
    @State private var controlsSize = AppleLayoutClass.keyWindow?.bounds.size ?? .zero
    #else
    @State private var controlsSize: CGSize = .zero
    #endif
    @Environment(\.horizontalSizeClass) private var pickerHorizontalSizeClass
    @State private var zapper = AppleLiveZapCoalescer()
    @Environment(\.scenePhase) private var scenePhase

    /// Shows the channel list unless a channel switch lands around the same
    /// touch: the video-area Button fires on the lift of a swipe too
    /// (test iPhone, 2026-10-06), so the show waits a beat and yields to a zap.
    private func requestChannelPicker() {
        pickerShowTask?.cancel()
        appleTrace("live picker requested swipe=\(swipeInProgress)")
        pickerShowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard !swipeInProgress else { appleTrace("live picker dropped: swipe"); return }
            if let lastChannelSwitch, ContinuousClock.now - lastChannelSwitch < .milliseconds(800) {
                appleTrace("live picker dropped: channel switch"); return
            }
            appleTrace("live picker shown")
            channelPicker.show()
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previousChannel: AppleIPTVChannel? {
        guard request.isLive, let currentChannelID,
              let id = AppleLiveWatchHistoryStore.shared.history.previous(currentID: currentChannelID,
                availableIDs: Set(channels.map(\.id))) else { return nil }
        return channels.first { $0.id == id }
    }

    private var lastChannelAction: (() -> Void)? {
        guard request.isLive else { return nil }
        if let onLastChannel { return onLastChannel }
        guard let previousChannel else { return nil }
        return { switchChannel(previousChannel) }
    }

    private func switchChannel(_ channel: AppleIPTVChannel) {
        AppleInteractionTrace.record(.press, "live zap → \(channel.name)")
        onSwitchChannel?(channel)
    }

    private func zap(_ direction: AppleLiveZappingPolicy.Direction) {
        guard request.isLive, !channelPicker.isPresented, let currentChannelID else { return }
        zapper.press(direction, currentID: currentChannelID, orderedIDs: channels.map(\.id)) { id, _ in
            guard let channel = channels.first(where: { $0.id == id }) else { return }
            switchChannel(channel)
        }
    }

    private var watchLiveAction: (() -> Void)? {
        guard !request.isLive, let channel = channels.first(where: { $0.id == currentChannelID }),
              let onSwitchChannel else { return nil }
        return {
            channelPicker.dismiss()
            onSwitchChannel(channel)
        }
    }

    /// Large windows browse channels in a strip along the bottom of the video;
    /// every other platform keeps the leading-edge panel.
    @ViewBuilder
    private var picker: some View {
        let onSelect: (AppleIPTVChannel) -> Void = { channel in
            channelPicker.select(channel) { switched in onSwitchChannel?(switched) }
        }
        let onDismiss: () -> Void = {
            channelPicker.dismiss()
            hideChromeSignal.toggle()
        }
        // While the picker is up the transport is out of the hit-test tree, so
        // its Close button cannot be reached: without this there is no way back
        // to the Live tab's guide except closing the picker first and waiting
        // for the chrome to come back (owner, 2026-09-20). Playback survives —
        // this is the same dismissal the Close button performs.
        // tvOS is left alone: its picker is a focus destination and a new
        // focusable control in the header would change where the remote lands.
        #if os(tvOS)
        let onBack: (() -> Void)? = nil
        #else
        let onBack: (() -> Void)? = {
            channelPicker.dismiss()
            onClose()
        }
        #endif
        #if os(iOS)
        // Hosted in UIKit, outside the root's environment: the root's rule, from this view's own size.
        let presentation = AppleLiveChannelPickerPresentation.choose(isLargeLayout: AppleLayoutClass.usesLargeLayout(
            isPad: UIDevice.current.userInterfaceIdiom == .pad, size: controlsSize,
            isRegularWidth: pickerHorizontalSizeClass == .regular))
        #else
        let presentation = AppleLiveChannelPickerPresentation.panel
        #endif
        switch presentation {
        case .bottomStrip:
            AppleLiveChannelStripOverlay(
                channels: channels, guide: guide, currentChannelID: currentChannelID,
                onSelect: onSelect, onDismiss: onDismiss, onBack: onBack,
                onWatchLive: watchLiveAction)
                .ignoresSafeArea(edges: .horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom))
        case .panel:
            AppleLiveChannelPickerOverlay(
                channels: channels, guide: guide, currentChannelID: currentChannelID,
                onSelect: onSelect, onDismiss: onDismiss, onBack: onBack)
                .frame(maxWidth: 340)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .leading))
        }
    }

    /// tvOS keeps its focus catcher: the picker there is a focus destination,
    /// not a touch target, and removing the surface would strand the engine.
    private var transportIsObscured: Bool {
        #if os(tvOS)
        false
        #else
        channelPicker.isPresented
        #endif
    }

    #if os(iOS)
    private var fullScreenFailureCause: AppleLiveFailureCause? {
        guard request.isLive, case .failed(let failure) = coordinator.phase else { return nil }
        let channel = channels.first { $0.id == currentChannelID }
        return AppleLiveFailureCause.playback(failure, channelName: channel?.displayName,
            sourceName: channel.flatMap { failureContext.sourceNames[$0.sourceID] })
    }

    private func performFailureAction(_ action: AppleLiveFailureCause.Action) {
        switch action {
        case .nextChannel: zap(.next)
        case .openSettings, .addSource:
            if let open = failureContext.onOpenSettings {
                onClose()
                open()
            } else { Task { await coordinator.retry() } }
        case .tryAgain: Task { await coordinator.retry() }
        }
    }
    #endif

    /// "ESPN · NFL Live" above the scrubber.
    private var nowPlaying: AppleLiveNowPlaying? {
        guard request.isLive, let currentChannelID,
              let channel = channels.first(where: { $0.id == currentChannelID }) else { return nil }
        let title = guide.nowAndNext(channelID: channel.id).now?.title
        return AppleLiveNowPlaying(logoURL: channel.logoURL,
            text: [channel.displayName, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if coordinator.route == .surface {
                ApplePlaybackSurfaceView(engine: coordinator.engine)
                    .ignoresSafeArea()
            }
            let transport = AppleTransportOverlay(
                coordinator: coordinator,
                request: request,
                onShowChannels: channels.isEmpty ? nil : { requestChannelPicker() },
                onLastChannel: lastChannelAction,
                onStartOver: request.isLive ? onStartOver : nil,
                isObscured: transportIsObscured,
                // A tap shows or hides the chrome, as in the system player; the
                // channel list opens from its own glyph (owner items 12–15).
                onBackgroundTap: { _ in
                    if channelPicker.isPresented { channelPicker.dismiss() }
                },
                onControlsVisibilityChanged: { isVisible in
                    if !isVisible && channelPicker.isPresented {
                        channelPicker.dismiss()
                    }
                },
                hideChromeSignal: hideChromeSignal,
                onClose: onClose,
                sharePlayMenu: sharePlayMenu,
                onWatchLive: watchLiveAction,
                onChannelStep: request.isLive && !channels.isEmpty ? { zap($0) } : nil,
                nowPlaying: nowPlaying
            )
            #if os(iOS)
            if fullScreenFailureCause != nil { Color.black.ignoresSafeArea() }
            #endif
            // Hidden from accessibility as well as from touch, on every
            // platform. `allowsHitTesting(false)` alone leaves the transport's
            // full-screen "Show playback controls" surface in the tree, and it
            // is then the element found at every point over the channel panel:
            // VoiceOver read the surface instead of the rows, and XCTest
            // reported every visible row unhittable (2026-09-19).
            transport
                .allowsHitTesting(!channelPicker.isPresented)
                .accessibilityHidden(channelPicker.isPresented)
            #if os(iOS)
            // The same card as the frame's, over black; close and the
            // chevrons stay reachable around it.
            if let cause = fullScreenFailureCause, !channelPicker.isPresented {
                AppleLiveFailureCard(cause: cause) { performFailureAction(cause.action) }
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif
            if channelPicker.isPresented {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture {
                        channelPicker.dismiss()
                        hideChromeSignal.toggle()
                    }
                picker
                    .zIndex(1)
            } else {
                AppleLiveZapPendingBanner(zapper: zapper, channels: channels)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Animation.default, value: channelPicker.isPresented)
        .onChange(of: request.mediaID) { _, new in
            appleTrace("live controls request changed → \(new)")
            lastChannelSwitch = .now
            pickerShowTask?.cancel()
            pickerShowTask = nil
        }
        .modifier(AppleSleepTimerPresentation(coordinator: coordinator))
        .modifier(ApplePINPresenter())
        #if os(iOS)
        // UIKit isolates the presented host. SwiftUI's isModal trait spreads
        // into caption nodes, making them synthetic alerts that hide controls.
        .background(ApplePlayerAccessibilityModal().frame(width: 0, height: 0))
        // The transport's full-screen "show channels" Button fires on any
        // touch that lifts inside it — gesture priority does not stop it — so
        // a channel swipe also opened the Channels list (test iPhone, 2026-10-06).
        // `swipeInProgress` is raised while the finger moves (before it
        // lifts) and the tap paths below ignore the touch while it is up.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 60)
            .onChanged { gesture in
                // Only the middle 60 % of the height zaps: the home-indicator
                // swipe and the scrubber live outside it.
                guard AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: gesture.startLocation.y,
                                                                  height: controlsSize.height) else { return }
                if !swipeInProgress,
                   AppleLiveZappingPolicy.swipe(horizontal: gesture.translation.width,
                                                vertical: gesture.translation.height) != nil {
                    swipeInProgress = true
                    appleTrace("live swipe recognised (SwiftUI)")
                }
            }
            .onEnded { gesture in
                if AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: gesture.startLocation.y, height: controlsSize.height),
                   let direction = AppleLiveZappingPolicy.swipe(horizontal: gesture.translation.width,
                    vertical: gesture.translation.height) { zap(direction) }
                // The Button's action runs on the same lift, in either order.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    swipeInProgress = false
                }
            }, including: channelPicker.isPresented ? .subviews : .all)
        .accessibilityAction(named: "Next Channel") { zap(.next) }
        .accessibilityAction(named: "Previous Channel") { zap(.previous) }
        #endif
        .onChange(of: currentChannelID) { _, id in zapper.playerChanged(to: id) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { zapper.cancel() } }
        .onDisappear { zapper.cancel() }
    }
}

/// Keeps the single AVPlayerViewController mounted while a live player moves
/// between the guide and a full-screen modal. Re-parenting this controller,
/// instead of rebuilding it on a size-class change, preserves the current item
/// and lets AVKit resize its layer during rotation.
private final class AppleLivePlayerContainerViewController: AppleLiveChromeViewController {
    private let playerViewController: AVPlayerViewController
    private let coordinator: ApplePlaybackCoordinator
    private var request: ApplePlaybackRequest
    private var fullScreenRevision = 0
    private var presentedRevision = 0
    private var presentationTask: Task<Void, Never>?
    private var liveMenu: AppleTransportOverlay.SharePlayMenu?
    private var playPauseButton: UIButton!
    private var muteButton: UIButton!
    private var fullscreenButton: UIButton!
    private var surfaceHost: UIHostingController<ApplePlaybackSurfaceView>?
    private let inlineSubtitles = AppleStockPlayerSubtitles()
    private var cueHost: UIHostingController<AppleLiveInlineCueLayer>?
    /// Mute, AirPlay and full screen, top-right, 4 pt apart.
    private var topTrailingStack: UIStackView!
    private let zapper = AppleLiveZapCoalescer()
    #if os(iOS)
    private var pendingBannerHost: UIHostingController<AppleLiveZapPendingBanner>?
    #endif
    private weak var presentedFullscreen: AppleLiveFullscreenPlayerViewController?
    /// Set on visionOS: full screen is the window's player stage.
    var onRequestFullWindow: (() -> Void)?
    var failureContext = AppleLiveFailureContext()
    private var channels: [AppleIPTVChannel]
    private var guide: AppleIPTVGuide
    private var currentChannelID: String?
    private var onSwitchChannel: ((AppleIPTVChannel) -> Void)?
    private var onLastChannel: (() -> Void)?
    private var onStartOver: (() -> Void)?
    private let onFullScreenChanged: (Bool) -> Void

    private var playerObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?

    init(playerViewController: AVPlayerViewController, coordinator: ApplePlaybackCoordinator, request: ApplePlaybackRequest, liveMenu: AppleTransportOverlay.SharePlayMenu?, channels: [AppleIPTVChannel] = [], guide: AppleIPTVGuide = AppleIPTVGuide(programmes: []), currentChannelID: String? = nil, onSwitchChannel: ((AppleIPTVChannel) -> Void)? = nil, onLastChannel: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil, onFullScreenChanged: @escaping (Bool) -> Void) {
        self.playerViewController = playerViewController
        self.onFullScreenChanged = onFullScreenChanged
        self.coordinator = coordinator
        self.request = request
        self.liveMenu = liveMenu
        self.channels = channels
        self.guide = guide
        self.currentChannelID = currentChannelID
        self.onSwitchChannel = onSwitchChannel
        self.onLastChannel = onLastChannel
        self.onStartOver = onStartOver
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Inline chrome (owner items 13 and 15, 2026-10-09): play/pause in
        // the centre; mute, AirPlay and full screen together top-right.
        // Nothing in the other corners: Last Channel lives in the full-screen
        // More menu and a swipe, captions in the full-screen player.
        playPauseButton = UIButton(type: .system)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: Self.playSymbol), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.accessibilityLabel = "Play"
        playPauseButton.accessibilityIdentifier = "player.play-pause"
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .primaryActionTriggered)
        Self.applyGlyphShadow(playPauseButton)

        muteButton = glyphButton("speaker.wave.2.fill", accessibilityLabel: "Mute")
        muteButton.accessibilityIdentifier = "player.mute"
        muteButton.addTarget(self, action: #selector(toggleMute), for: .primaryActionTriggered)

        fullscreenButton = glyphButton("arrow.up.left.and.arrow.down.right", accessibilityLabel: "Full Screen")
        fullscreenButton.accessibilityIdentifier = "player.fullscreen"
        fullscreenButton.addTarget(self, action: #selector(requestFullScreen), for: .primaryActionTriggered)

        var trailing: [UIView] = [muteButton]
        #if os(iOS)
        let route = AppleLiveRouteButton()
        route.translatesAutoresizingMaskIntoConstraints = false
        route.widthAnchor.constraint(equalToConstant: AppleDesignTokens.minimumActionSize).isActive = true
        route.heightAnchor.constraint(equalToConstant: AppleDesignTokens.minimumActionSize).isActive = true
        Self.applyGlyphShadow(route)
        trailing.append(route)
        #endif
        trailing.append(fullscreenButton)
        topTrailingStack = UIStackView(arrangedSubviews: trailing)
        topTrailingStack.axis = .horizontal
        topTrailingStack.spacing = 4
        topTrailingStack.translatesAutoresizingMaskIntoConstraints = false
        #if os(iOS)
        for direction: UISwipeGestureRecognizer.Direction in [.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeChannel(_:)))
            swipe.direction = direction
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
        #endif
        view.addSubview(playPauseButton)
        view.addSubview(topTrailingStack)
        #if os(iOS)
        addPendingBanner()
        NotificationCenter.default.addObserver(self, selector: #selector(cancelZap),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        #endif

        NSLayoutConstraint.activate([
            playPauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            playPauseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            playPauseButton.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            topTrailingStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            topTrailingStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
        ])

        updateChromeButtons()
        attachPlayerIfNeeded()
        
        // KVO calls back on whichever thread changed the value, with no main-queue
        // guarantee, so every observer below hops to the main actor explicitly.
        playerObservation = playerViewController.observe(\.player, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePlayer(self.playerViewController.player)
            }
        }
    }
    
    private func observePlayer(_ player: AVPlayer?) {
        // The hops can land out of order, so each one re-reads the player's current
        // state on the main actor instead of carrying the value it was fired with.
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlayPauseButton() }
        }
        muteObservation = player?.observe(\.isMuted, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateMuteButton() }
        }
    }

    private static let playSymbol = UIImage.SymbolConfiguration(
        pointSize: ApplePlayerControlMetrics.transportPointSize, weight: .semibold)

    /// The 40 % shadow every glyph over the video carries; no plate behind it.
    private static func applyGlyphShadow(_ view: UIView) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.4
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = .zero
    }

    private func glyphButton(_ symbol: String, accessibilityLabel: String) -> UIButton {
        let button = menuButton(imageName: symbol, accessibilityLabel: accessibilityLabel, menu: nil)
        button.setImage(UIImage(systemName: symbol, withConfiguration: AppleLivePlayerGlyph.symbol), for: .normal)
        Self.applyGlyphShadow(button)
        return button
    }

    private func updatePlayPauseButton() {
        let isPlaying = playerViewController.player?.timeControlStatus == .playing
        playPauseButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill", withConfiguration: Self.playSymbol), for: .normal)
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    private func updateMuteButton() {
        let isMuted = playerViewController.player?.isMuted ?? false
        muteButton.setImage(UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    withConfiguration: AppleLivePlayerGlyph.symbol), for: .normal)
        muteButton.accessibilityLabel = isMuted ? "Unmute" : "Mute"
    }

    func setBusy(_ busy: Bool, keepsPicture: Bool) {
        guard isViewLoaded else { return }
        playerViewController.view.alpha = busy && !keepsPicture ? 0 : 1
        playerViewController.view.accessibilityElementsHidden = busy
        playPauseButton.alpha = busy ? 0 : 1
        playPauseButton.isUserInteractionEnabled = !busy
    }
    
    @objc private func togglePlayPause() {
        if coordinator.phase == .playing {
            coordinator.engine.pause()
        } else {
            coordinator.engine.play()
        }
    }
    
    private func updateChromeButtons() {
        chromeViews = [playPauseButton, topTrailingStack]
    }

    #if os(iOS)
    private func addPendingBanner() {
        let hosting = UIHostingController(rootView: AppleLiveZapPendingBanner(zapper: zapper, channels: channels))
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.insertSubview(hosting.view, belowSubview: playPauseButton)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        pendingBannerHost = hosting
    }

    @objc private func cancelZap() {
        zapper.cancel()
    }

    @objc private func swipeChannel(_ gesture: UISwipeGestureRecognizer) {
        guard request.isLive, let currentChannelID else { return }
        zapper.press(gesture.direction == .up ? .next : .previous, currentID: currentChannelID,
                     orderedIDs: channels.map(\.id)) { [weak self] id, _ in
            guard let self, let channel = channels.first(where: { $0.id == id }) else { return }
            AppleInteractionTrace.record(.press, "live zap → \(channel.name)")
            onSwitchChannel?(channel)
        }
    }
    #endif

    @objc private func toggleMute() {
        guard let player = playerViewController.player else { return }
        player.isMuted.toggle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachPlayerIfNeeded()
        updateInlineSurface()
        presentRequestedFullScreen()
    }

    func attachPlayerIfNeeded() {
        guard playerViewController.parent == nil, presentedFullscreen == nil else { return }
        playerViewController.showsPlaybackControls = false
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

    private func updateInlineSurface() {
        updateInlineCues()
        guard coordinator.route == .surface, presentedFullscreen == nil else {
            removeInlineSurface()
            return
        }
        guard surfaceHost == nil, playerViewController.parent === self else { return }
        let hosting = UIHostingController(rootView: ApplePlaybackSurfaceView(engine: coordinator.engine))
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.insertSubview(hosting.view, aboveSubview: playerViewController.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        surfaceHost = hosting
    }

    private func updateInlineCues() {
        guard presentedFullscreen == nil, playerViewController.parent === self else { return }
        guard cueHost == nil else { return }
        let hosting = UIHostingController(rootView: AppleLiveInlineCueLayer(
            engine: coordinator.engine, subtitles: inlineSubtitles))
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        // Keep the full-frame cue host below the controls. Its non-interactive
        // view still participates in accessibility hit testing.
        view.insertSubview(hosting.view, aboveSubview: playerViewController.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        cueHost = hosting
    }

    private func removeInlineCues() {
        cueHost?.willMove(toParent: nil)
        cueHost?.view.removeFromSuperview()
        cueHost?.removeFromParent()
        cueHost = nil
    }

    private func removeInlineSurface() {
        surfaceHost?.willMove(toParent: nil)
        surfaceHost?.view.removeFromSuperview()
        surfaceHost?.removeFromParent()
        surfaceHost = nil
    }

    func update(request: ApplePlaybackRequest, liveMenu: AppleTransportOverlay.SharePlayMenu?,
                channels: [AppleIPTVChannel], guide: AppleIPTVGuide, currentChannelID: String?,
                onSwitchChannel: ((AppleIPTVChannel) -> Void)?,
                onLastChannel: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil,
                fullScreenRevision: Int) {
        self.request = request
        self.liveMenu = liveMenu
        self.channels = channels
        self.guide = guide
        self.currentChannelID = currentChannelID
        self.onSwitchChannel = onSwitchChannel
        self.onLastChannel = onLastChannel
        self.onStartOver = onStartOver
        self.fullScreenRevision = fullScreenRevision
        zapper.playerChanged(to: currentChannelID)
        #if os(iOS)
        pendingBannerHost?.rootView = AppleLiveZapPendingBanner(zapper: zapper, channels: channels)
        #endif
        if isViewLoaded {
            updateInlineSurface()
            updateChromeButtons()
        }
        if isViewLoaded {
            let playing = coordinator.phase == .playing
            playPauseButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill",
                withConfiguration: Self.playSymbol), for: .normal)
            playPauseButton.accessibilityLabel = playing ? "Pause" : "Play"
        }
        presentedFullscreen?.failureContext = failureContext
        presentedFullscreen?.update(request: request, liveMenu: liveMenu,
                                    channels: channels, guide: guide, currentChannelID: currentChannelID,
                                    onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver)
        // UIKit presentation calls back into SwiftUI state; leave this update first.
        if fullScreenRevision != presentedRevision, presentationTask == nil {
            presentationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.presentationTask = nil
                self.presentRequestedFullScreen()
            }
        }
    }

    private func presentRequestedFullScreen() {
        guard fullScreenRevision != presentedRevision, viewIfLoaded?.window != nil else { return }
        if presentedFullscreen != nil {
            presentedRevision = fullScreenRevision
        } else {
            requestFullScreen()
        }
    }

    func restorePlayer() {
        presentedFullscreen = nil
        attachPlayerIfNeeded()
        updateInlineSurface()
        onFullScreenChanged(false)
        showControls()
    }

    @objc private func requestFullScreen() {
        if let onRequestFullWindow, presentedFullscreen == nil {
            presentedRevision = fullScreenRevision
            onRequestFullWindow()
            return
        }
        guard presentedFullscreen == nil, presentedViewController == nil,
              playerViewController.presentingViewController == nil else { return }
        presentedRevision = fullScreenRevision
        onFullScreenChanged(true)
        removeInlineCues()
        removeInlineSurface()
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
        let fullscreen = AppleLiveFullscreenPlayerViewController(
            playerViewController: playerViewController,
            inlineContainer: self,
            coordinator: coordinator,
            request: request,
            liveMenu: liveMenu,
            channels: channels,
            guide: guide,
            currentChannelID: currentChannelID,
            onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver,
            failureContext: failureContext
        )
        presentedFullscreen = fullscreen
        // Retain the guide's view hierarchy and its loading task while AVKit
        // owns the single player controller in the modal.
        fullscreen.modalPresentationStyle = .overFullScreen
        present(fullscreen, animated: true)
    }
}

private final class AppleLiveFullscreenPlayerViewController: UIViewController {
    private let playerViewController: AVPlayerViewController
    private let coordinator: ApplePlaybackCoordinator
    private weak var inlineContainer: AppleLivePlayerContainerViewController?
    private let controlsHost: UIHostingController<AppleLiveFullScreenControls>
    private let channelPicker = AppleLiveChannelPickerState()
    var failureContext: AppleLiveFailureContext

    init(playerViewController: AVPlayerViewController, inlineContainer: AppleLivePlayerContainerViewController,
         coordinator: ApplePlaybackCoordinator, request: ApplePlaybackRequest,
         liveMenu: AppleTransportOverlay.SharePlayMenu?, channels: [AppleIPTVChannel],
         guide: AppleIPTVGuide, currentChannelID: String?,
         onSwitchChannel: ((AppleIPTVChannel) -> Void)?, onLastChannel: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil,
         failureContext: AppleLiveFailureContext = AppleLiveFailureContext()) {
        self.failureContext = failureContext
        self.playerViewController = playerViewController
        self.inlineContainer = inlineContainer
        self.coordinator = coordinator
        controlsHost = UIHostingController(rootView: AppleLiveFullScreenControls(
            coordinator: coordinator, request: request, sharePlayMenu: liveMenu,
            channels: channels, guide: guide, currentChannelID: currentChannelID,
            onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver, onClose: {},
            channelPicker: channelPicker, failureContext: failureContext))
        super.init(nibName: nil, bundle: nil)
        update(request: request, liveMenu: liveMenu, channels: channels,
               guide: guide, currentChannelID: currentChannelID, onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(request: ApplePlaybackRequest, liveMenu: AppleTransportOverlay.SharePlayMenu?,
                channels: [AppleIPTVChannel], guide: AppleIPTVGuide, currentChannelID: String?,
                onSwitchChannel: ((AppleIPTVChannel) -> Void)?, onLastChannel: (() -> Void)? = nil, onStartOver: (() -> Void)? = nil) {
        controlsHost.rootView = AppleLiveFullScreenControls(
            coordinator: coordinator, request: request, sharePlayMenu: liveMenu,
            channels: channels, guide: guide, currentChannelID: currentChannelID,
            onSwitchChannel: onSwitchChannel, onLastChannel: onLastChannel, onStartOver: onStartOver,
            onClose: { [weak self] in self?.dismiss(animated: true) },
            channelPicker: channelPicker, failureContext: failureContext)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // AVKit owns picture/caption rendering; the shared overlay owns all controls.
        view.accessibilityViewIsModal = true
        playerViewController.showsPlaybackControls = false
        playerViewController.videoGravity = .resizeAspect
        controlsHost.view.backgroundColor = .clear
        for child in [playerViewController, controlsHost] as [UIViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            child.didMove(toParent: self)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        AppleOrientationLock.shared.allowsLandscape = true
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        #if os(iOS)
        AppleOrientationLock.shared.allowsLandscape = false
        #endif
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
        controlsHost.willMove(toParent: nil)
        controlsHost.view.removeFromSuperview()
        controlsHost.removeFromParent()
        inlineContainer?.restorePlayer()
    }

    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    #endif
}

/// The inline preview hides play, mute, captions and full-screen controls together.
private class AppleLiveChromeViewController: UIViewController, UIGestureRecognizerDelegate {
    var chromeViews: [UIView] = []
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
        chromeViews.forEach { $0.isHidden = false }
        // The same Debug-only capture hook used by full-screen transport.
        guard !AppleTransportOverlayModel.chromeIsHeldOpen else { return }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.chromeViews.forEach { $0.isHidden = true }
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
        button.widthAnchor.constraint(equalToConstant: AppleDesignTokens.minimumActionSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: AppleDesignTokens.minimumActionSize).isActive = true
        return button
    }

}

#endif

private struct AppleLiveSearchModifier<Results: View>: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String
    @Binding var showsSearch: Bool
    let dismissal: Int
    let playbackRevision: Int
    /// A Live TV link's or a reminder's channel, waiting for the Live page.
    let channelRequest: String?
    @ViewBuilder let results: () -> Results
    @State private var searchPresented = false
    /// Search was asked to leave while its field was active: the page pops once the field has ended.
    @State private var leavesWhenSearchEnds = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        // The toolbar item and the destination stay attached whether or not channels have
        // loaded yet: adding/removing them while the tab appears relayouts the navigation bar
        // mid-transition, which trips a UINavigationBar layoutSubviews assertion on iOS 18.
        content
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    searchButton
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    searchButton
                }
                #endif
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { dismiss() }
            }
            .onChange(of: dismissal) { dismiss() }
            .onChange(of: showsSearch) { _, presented in
                leavesWhenSearchEnds = false
                if !presented {
                    searchPresented = false
                }
            }
            .navigationDestination(isPresented: $showsSearch) {
                results()
                    .modifier(AppleSearchEndObserver(isLeaving: leavesWhenSearchEnds) {
                        leavesWhenSearchEnds = false
                        showsSearch = false
                    })
                    .searchable(text: $query, isPresented: $searchPresented, prompt: "Channels and groups")
                    .task {
                        searchPresented = true
                    }
                    // The Live page sleeps while Search covers it, so Search leaves by
                    // itself when any start lands (the strip, failover, SharePlay) or a
                    // link asks for a channel the page can only start once it shows.
                    .onChange(of: playbackRevision) { dismiss() }
                    .onChange(of: channelRequest) { _, id in
                        if id != nil { dismiss() }
                    }
                    // The filter clears once the page is gone, so the list does not
                    // flash unfiltered while it slides out; a tab switch keeps it.
                    .onDisappear {
                        if !showsSearch { query = "" }
                    }
                    .navigationTitle("Search")
                    #if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        #endif
    }

    #if !os(tvOS)
    /// The field ends first, then the page pops. Observed on iPadOS 26.x (owner iPad
    /// 2026-10-28, a pick while a playlist reload waited): popping while the field was
    /// still active left the tab bar hidden until Search was opened and closed again.
    private func dismiss() {
        switch AppleLiveSearchExit.next(isShown: showsSearch, fieldPresented: searchPresented,
                                        isLeaving: leavesWhenSearchEnds) {
        case .pop:
            showsSearch = false
        case .endFieldFirst:
            leavesWhenSearchEnds = true
            searchPresented = false
        case nil:
            break
        }
    }

    private var searchButton: some View {
        Button {
            showsSearch = true
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .accessibilityLabel("Search")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0)
        .accessibilityHidden(!isEnabled)
    }
    #endif
}

#if !os(tvOS)
/// Calls `onEnd` while `isLeaving` is set, once the surrounding `.searchable` field
/// has ended and finished animating away, or after `AppleLiveSearchExit.deadline`
/// if the field never reports its end.
private struct AppleSearchEndObserver: ViewModifier {
    let isLeaving: Bool
    let onEnd: () -> Void
    @Environment(\.isSearching) private var isSearching

    func body(content: Content) -> some View {
        content
            .task(id: isLeaving && !isSearching) {
                guard isLeaving, !isSearching else { return }
                try? await Task.sleep(for: AppleLiveSearchExit.fieldCollapse)
                guard !Task.isCancelled else { return }
                onEnd()
            }
            .task(id: isLeaving) {
                guard isLeaving else { return }
                try? await Task.sleep(for: AppleLiveSearchExit.deadline)
                guard !Task.isCancelled else { return }
                onEnd()
            }
    }
}
#endif

#if os(tvOS)
struct AppleTVChannelSearchEditor: View {
    @Binding var query: String

    var body: some View {
        Form {
            Section {
                TextField("Channel or group", text: $query)
                    .accessibilityLabel("Search channels or groups")
            }
            if !query.isEmpty {
                Section {
                    // Not destructive: clearing a search loses nothing, and
                    // the role painted the label red (no coloured label text).
                    Button {
                        query = ""
                    } label: {
                        AppleTVFocusReadableText("Clear Search")
                    }
                    .accessibilityIdentifier("live.search.clear")
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
            hints: ApplePlaybackRequest.Hints(filename: item.name, libraryFileURL: item.url)
        )
    }
}

#if os(iOS)
/// Keeps the menu action and its accessibility target on the same native button.
@MainActor
private struct AppleLibrarySortButton: UIViewRepresentable {
    @Binding var sort: AppleLibrarySort

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
            configuration.cornerStyle = .capsule
        } else {
            configuration = .plain()
            let backingDiameter = AppleDesignTokens.spacingExtraLarge
            let inset = (AppleDesignTokens.minimumActionSize - backingDiameter) / 2
            configuration.background = .clear()
            configuration.background.visualEffect = UIBlurEffect(style: .regular)
            configuration.background.backgroundInsets = NSDirectionalEdgeInsets(
                top: inset, leading: inset, bottom: inset, trailing: inset)
            configuration.background.cornerRadius = backingDiameter / 2
            configuration.cornerStyle = .fixed
        }
        configuration.image = UIImage(systemName: "arrow.up.arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body).applying(UIImage.SymbolConfiguration(weight: .semibold)))
        configuration.baseForegroundColor = .white
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = "Sort library"
        button.accessibilityIdentifier = "library.sort"
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = UIMenu(options: .singleSelection, children: AppleLibrarySort.allCases.map { option in
            UIAction(title: option.rawValue, state: sort == option ? .on : .off) { _ in
                sort = option
            }
        })
    }
}
#endif

#if os(tvOS)
/// A plain button that opens the choices in a dialog, not a `Menu`: focus
/// that reached a `Menu` here never left it on Up once the billboard had
/// scrolled away (test Apple TV walk 2026-11-04), so the tab bar was unreachable.
private struct AppleTVLibrarySortButton: View {
    @Binding var sort: AppleLibrarySort
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort library")
            .accessibilityValue(sort.rawValue)
            .accessibilityIdentifier("library.sort")
            .buttonStyle(AppleTVGlyphStyle())
            .font(.system(size: AppleTVChromeMetrics.glyphFontSize, weight: .semibold))
            .confirmationDialog("Sort", isPresented: $choosing) {
                ForEach(AppleLibrarySort.allCases) { option in
                    Button(option.rawValue) { sort = option }
                }
            }
    }
}
#endif

@MainActor
struct AppleLibraryView: View {
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleUsesPadLandingChrome) private var usesPadLandingChrome
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var phoneHeroLayout = AppleHomePhoneHeroLayout()
    @State private var padHeroLayout = AppleMacHeroLayout(platform: .pad)
    @State private var library = AppleLocalLibraryStore.shared
    @State private var continuing: [AppleLibrarySeries] = []
    @State private var progressRevision = 0
    @State private var viewportSize: CGSize = .zero
    /// The page's side safe areas, which the hero's art runs under (`AppleHeroSideBleed`).
    @State private var sideInsets = EdgeInsets()
    @State private var selectedHero: AppleLibrarySeries?
    @State private var selectedHeroAutoPlay = false
    @State private var showsSelectedHero = false
    /// Textless hero art, keyed by media id, once TMDB has been asked for it.
    /// Empty is the normal state on first paint — see `upgradeHeroArtwork`.
    @State private var heroArtwork: [String: AppleHeroArtworkUpgrade.Artwork] = [:]
    @State private var heroWordmarksResolved: Set<String> = []
    #if os(macOS)
    /// The same hero geometry as Discover's (`AppleMacHeroLayout`).
    @State private var macHeroLayout = AppleMacHeroLayout()
    #endif
    @AppStorage("openstream.library.sort") private var sort = AppleLibrarySort.defaultSort
    #if !os(tvOS)
    @State private var showsSearch = false
    #endif
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    var mediaServerLibrary: AppleMediaServerLibraryStore? = nil

    private var groups: [AppleLibrarySeries] { library.sorted(sort) }

    #if os(tvOS)
    private let sectionSpacing: CGFloat = AppleTVBillboardMetrics.sectionSpacing
    #else
    private let sectionSpacing: CGFloat = 32
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
        AppleXtreamLibraryStore.shared.shelves.isEmpty && AppleXtreamLibraryStore.shared.failures.isEmpty
            && !AppleXtreamLibraryStore.shared.isLoading && groups.isEmpty && continuing.isEmpty
            && library.featuredCandidates.isEmpty && !library.isLoading
    }

    var body: some View {
        Group {
            if hasNothingToShow, let error = library.errorMessage {
                // A share that refused access read as "No Videos" (full test
                // 2026-09-30); the scan's own error is the title instead.
                AppleSourceEmptyState(title: error, systemImage: OpenStreamTab.library.systemImage,
                                      actionTitle: "Try Again", action: { Task { await reload() } },
                                      secondaryActionTitle: "Open Settings", secondaryAction: openSettings)
            } else if hasNothingToShow {
                AppleSourceEmptyState(title: "No Videos", systemImage: OpenStreamTab.library.systemImage,
                                      actionTitle: "Open Settings", action: openSettings)
            } else {
                libraryScroll
            }
        }
        .navigationDestination(isPresented: $showsSelectedHero) {
            if let selectedHero {
                detail(selectedHero, autoPlay: selectedHeroAutoPlay)
            }
        }
        #if !os(tvOS)
        // The same Search and Refresh as Discover, in the empty state too.
        .toolbar {
            #if os(iOS)
            if usesPadLandingChrome { libraryToolbar }
            #else
            libraryToolbar
            #endif
        }
        #if os(iOS)
        .modifier(ApplePhoneLandingChrome(title: "Library", identifier: "library.compact-title",
            hasHero: !hasNothingToShow && (!library.featuredCandidates.isEmpty
                || !AppleHeroRotation.candidates(AppleXtreamLibraryStore.shared.shelves.flatMap(\.preview),
                    id: \.id, hasBackdrop: AppleHeroRotation.hasBackdrop).isEmpty),
            isRefreshing: library.isLoading || AppleXtreamLibraryStore.shared.isLoading,
            onSearch: { showsSearch = true }, onRefresh: { Task { await reload() } }) {
                AppleLibrarySortButton(sort: $sort)
                    .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
            })
        #endif
        #if os(macOS)
        .onChange(of: AppleMacCommandCenter.shared.refreshRevision) {
            guard AppleMacCommandCenter.shared.refreshTarget == .library, !library.isLoading else { return }
            appleTrace("library refresh from the menu")
            Task { await reload() }
        }
        #endif
        .navigationDestination(isPresented: $showsSearch) {
            // Its own router: deep links belong to Discover's Search, and two
            // views answering one route would push it twice.
            AppleSearchView(sourceStore: sourceStore, mediaIndex: mediaIndex,
                            router: AppleAppRouter(), settings: settings, openSettings: openSettings,
                            mediaServerLibrary: mediaServerLibrary)
                .navigationTitle("Search")
                .appleTraceScreen("search")
                .environment(\.appleTabToolbar, tabToolbarContext)
        }
        #endif
        #if !os(tvOS)
        // The same Search and Refresh on every page pushed from here.
        .environment(\.appleTabToolbar, tabToolbarContext)
        #endif
        // Discover's artwork lookup for the hero and title pages too.
        .environment(\.appleTMDBConfiguration, settings.tmdbConfiguration)
        .appleTraceScreen("library", detail: "\(groups.count) titles, loading=\(library.isLoading)")
    }

    private var heroPresentation: AppleHomePresentationPolicy.Hero {
        AppleHomeHeroCarousel<EmptyView>.presentation(viewport: viewportSize,
            compact: horizontalSizeClass == .compact, accessibility: dynamicTypeSize.isAccessibilitySize,
            isLargeLayout: isLargeLayout)
    }

    private var rowStyle: AppleDiscoverRowStyle? {
        #if os(macOS)
        AppleHomePresentationPolicy.rows(hero: heroPresentation,
            width: macHeroLayout.contentWidth, inset: macHeroLayout.horizontalPadding)
        #else
        AppleHomePresentationPolicy.rows(hero: heroPresentation, width: viewportSize.width, inset: 16)
        #endif
    }

    private func homeHero(_ heroes: [AppleLibrarySeries]) -> some View {
        #if os(macOS)
        let wideLayout = macHeroLayout
        #else
        let wideLayout = padHeroLayout
        #endif
        return AppleHomeHeroCarousel(pageIDs: heroes.map(\.id), items: heroes.map(heroItem),
            wordmarks: heroes.map { heroItem($0).logoURL }, viewportSize: viewportSize,
            phoneLayout: phoneHeroLayout, wideLayout: wideLayout) { index, failed, mode, count, shown, tv in
            heroPage(heroes[index], mode: mode, failed: failed, count: count, index: shown, tv: tv)
        }
        .task(id: heroUpgradeIdentity(heroes)) { await upgradeHeroArtwork(heroes) }
    }

    private func heroPage(_ group: AppleLibrarySeries, mode: AppleHomePresentationPolicy.Hero,
                          failed: Bool, count: Int, index: Int, tv: AppleHomeTVHeroContext?) -> some View {
        let item = heroItem(group)
        let recordID = group.items.first.map(library.playbackID) ?? group.id
        let listID = group.items.first.map { AppleMediaIngestion.catalogRecord(instanceID: $0.sourceID, item: item).id }
        let isInList = listID.flatMap { mediaIndex.record(id: $0) }?.isFavorite ?? false
        return AppleHomeBillboard(item: item, sources: sourceStore.sources, progressID: recordID,
            preferredSourceID: group.items.first?.sourceID ?? AppleSource.ID(),
            onPlay: { selectHero(group, autoPlay: true) }, onOpenDetails: { selectHero(group, autoPlay: false) },
            settings: settings, viewportSize: viewportSize, wordmark: failed ? nil : item.logoURL,
            wordmarkLookupPending: AppleHeroTitlePolicy.wordmarkLookupPending(
                mediaID: item.mediaID, resolved: heroWordmarksResolved, wordmarkFailed: failed),
            rotationCount: count, rotationIndex: index, mediaServerLibrary: mediaServerLibrary,
            phone: mode == .phone ? .init(artHeight: phoneHeroLayout.artHeight, copyFadeLine: phoneHeroLayout.topInset) : nil,
            mac: mode == .mac || mode == .pad ? .init(layout: wideHeroLayout) : nil,
            tv: tv.map { .init(cycle: $0.cycle) }, libraryButton: heroButton(group, item: item)
        ) { button, perform in
            AppleHomeHeroActions(mode: mode, viewportSize: viewportSize, button: button,
                isInList: isInList, tv: tv, onPlay: perform,
                onToggleList: { toggleList(group) }, onDetails: { selectHero(group, autoPlay: false) })
        }
    }

    private var wideHeroLayout: AppleMacHeroLayout {
        #if os(macOS)
        macHeroLayout
        #else
        padHeroLayout
        #endif
    }

    private func toggleList(_ group: AppleLibrarySeries) {
        guard let file = group.items.first,
              let source = library.sources.first(where: { $0.id == file.sourceID }) else { return }
        let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: library.catalogItem(for: group))
        Task {
            let favorite = mediaIndex.record(id: record.id)?.isFavorite ?? false
            if mediaIndex.record(id: record.id) == nil { try? await mediaIndex.upsert(record) }
            try? await mediaIndex.setFavorite(!favorite, recordID: record.id)
        }
    }

    /// Play or Resume from the file on disk, whatever the catalog sources say.
    private func heroButton(_ featured: AppleLibrarySeries, item: AppleCatalogItem) -> AppleTitlePagePolicy.HeroButton {
        AppleTitlePagePolicy.HeroButton(action: AppleTitlePagePolicy.heroPrimaryAction(
            type: item.type, progress: library.progress[featured.id],
            selectedEpisode: library.resumeEpisode(for: item, group: featured,
                episodes: AppleLocalLibraryStore.episodes(group: featured, mediaID: item.mediaID, enriched: [])),
            isPlayable: AppleTitlePagePolicy.hasPlaybackRoute(item: item, hasLocalGroup: true),
            trailer: .none))
    }

    /// The hero's own record, with any textless art that has since arrived.
    private func heroItem(_ group: AppleLibrarySeries) -> AppleCatalogItem {
        let item = library.catalogItem(for: group)
        guard let upgrade = heroArtwork[item.mediaID] else { return item }
        return item.withHeroArtwork(backgroundURL: upgrade.backdropURL, logoURL: upgrade.logoURL)
    }

    private func heroUpgradeIdentity(_ heroes: [AppleLibrarySeries]) -> String {
        heroes.map { library.catalogItem(for: $0).mediaID }.joined(separator: ",")
    }

    /// Asks TMDB for a backdrop with no title burned into it, for the handful
    /// of titles the billboard rotates through.
    ///
    /// Never on the way to first paint: the hero has already drawn the art the
    /// Library resolver cached for it, and this only swaps that art if a
    /// textless one exists. `AppleHeroArtworkUpgrade` answers from the
    /// metadata disk cache after the first visit, so the swap is a first-run
    /// event, not something the viewer sees every time.
    private func upgradeHeroArtwork(_ heroes: [AppleLibrarySeries]) async {
        for group in heroes {
            let item = library.catalogItem(for: group)
            guard let configuration = settings.tmdbConfiguration else {
                heroWordmarksResolved.insert(item.mediaID)
                continue
            }
            guard heroArtwork[item.mediaID] == nil else {
                heroWordmarksResolved.insert(item.mediaID)
                continue
            }
            await AppleHeroTitlePolicy.resolveWordmark {
                await AppleHeroArtworkUpgrade.shared.artwork(for: item,
                    hasLibraryMetadataMatch: library.metadata[group.id] != nil, configuration: configuration)
            } apply: { upgrade in
                heroArtwork[item.mediaID] = upgrade
            } didResolve: {
                heroWordmarksResolved.insert(item.mediaID)
            }
            guard !Task.isCancelled else { return }
        }
    }

    private func selectHero(_ group: AppleLibrarySeries, autoPlay: Bool) {
        selectedHero = group
        selectedHeroAutoPlay = autoPlay
        showsSelectedHero = true
    }

    /// Library's Recently Added row; its titles are left out of the kind rows.
    private var recentlyAdded: [AppleLibrarySeries] {
        AppleLibraryShelfLayout.recentlyAdded(newestFirst: library.sorted(.added), limit: Self.recentlyAddedLimit)
    }
    private static let recentlyAddedLimit = 24
    private typealias KindShelf = (kind: AppleLibraryTitle.Kind, titles: [AppleLibrarySeries], row: [AppleLibrarySeries])

    /// Per source, in display order, each kind row that has titles left once
    /// Recently Added has taken its own: the full list and the row's titles.
    private func kindShelves(recent: [AppleLibrarySeries]) -> [[KindShelf]] {
        let sorted = groups
        return library.sources.map { source in
            let local = sorted.filter { $0.items.first?.sourceID == source.id }
            return [AppleLibraryTitle.Kind.movie, .show, .other].compactMap { kind in
                let titles = local.filter { $0.parsed.kind == kind }
                let row = AppleLibraryShelfLayout.row(titles, excluding: recent)
                return row.isEmpty ? nil : (kind, titles, row)
            }
        }
    }

    /// The per-source, per-kind shelves, kept separate from the scroll body
    /// so every platform can type-check each section independently.
    private func sourceShelves(_ perSource: [[KindShelf]]) -> some View {
        let accessory = AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: perSource.map { $0.map(\.kind.rawValue) })
        return ForEach(Array(zip(library.sources.indices, library.sources)), id: \.1.id) { sourceIndex, source in
            ForEach(perSource[sourceIndex], id: \.kind.rawValue) { entry in
                // One library source reads "Movies" / "Shows"; the
                // source name only disambiguates when there are several (Z9).
                let kindName = entry.kind == .movie ? "Movies" : entry.kind == .show ? "Shows" : "Other"
                let name = library.sources.count > 1 ? "\(kindName) · \(source.name)" : kindName
                let isFirstShelf = accessory.map { $0.sourceIndex == sourceIndex && $0.kind == entry.kind.rawValue } ?? false
                shelf(name, entry.titles, rowGroups: entry.row, accessory: isFirstShelf ? sortAccessory : nil)
            }
        }
    }

    private var genreShelves: some View {
        ForEach(library.genreShelves(sort), id: \.genre) { shelf($0.genre, $0.groups) }
    }

    #if !os(tvOS)
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(AppleLibrarySort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: { Label("Sort library", systemImage: "arrow.up.arrow.down") }
        .accessibilityIdentifier("library.sort")
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: libraryToolbarPlacement) { sortMenu }
        AppleTabToolbar(tab: .library, isRefreshing: library.isLoading || AppleXtreamLibraryStore.shared.isLoading,
                        onSearch: { showsSearch = true }, onRefresh: { Task { await reload() } })
    }
    #endif

    private var libraryScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                let heroes = library.featuredCandidates
                Group {
                    if !heroes.isEmpty {
                        homeHero(heroes)
                    } else {
                        let providerHeroes = AppleHeroRotation.candidates(
                            AppleXtreamLibraryStore.shared.shelves.flatMap(\.preview), id: \.id,
                            hasBackdrop: AppleHeroRotation.hasBackdrop)
                        if !providerHeroes.isEmpty {
                            AppleXtreamLibraryHero(items: providerHeroes, sourceStore: sourceStore, mediaIndex: mediaIndex,
                                settings: settings, openSettings: openSettings, viewportSize: viewportSize,
                                phoneLayout: phoneHeroLayout, wideLayout: wideHeroLayout)
                        }
                    }
                }
                #if os(iOS)
                .modifier(AppleHeroSideBleed(insets: sideInsets))
                #endif
                if let error = library.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").padding(.horizontal, 16)
                }
                let resumable = continuing
                if !resumable.isEmpty { shelf("Continue Watching", resumable, progress: true) }
                let recent = recentlyAdded
                if !recent.isEmpty { shelf("Recently Added", recent, opensFullList: false) }
                let perSource = kindShelves(recent: recent)
                sourceShelves(perSource)
                AppleXtreamLibrarySections(sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settings, openSettings: openSettings,
                    accessory: perSource.allSatisfy(\.isEmpty) ? sortAccessory : nil)
                genreShelves
                let unmatched = library.unmatched
                if !unmatched.isEmpty {
                    AppleLibraryUnmatchedShelf(groups: unmatched, sourceStore: sourceStore, settings: settings)
                }
                if (library.isLoading || AppleXtreamLibraryStore.shared.isLoading) && groups.isEmpty
                    && AppleXtreamLibraryStore.shared.shelves.isEmpty {
                    AppleSourceLoadingState()
                        .appleCentredInViewport(viewportSize)
                }
            }
            .environment(\.appleDiscoverRows, rowStyle)
            #if os(tvOS)
            .padding(.bottom, AppleTVBillboardMetrics.contentBottomInset)
            #else
            .padding(.vertical)
            #endif
        }.scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .overlay(alignment: .topTrailing) {
            if library.isLoading, library.scannedFileCount > 0 {
                ProgressView("\(library.scannedFileCount.formatted()) files")
                    .controlSize(.small)
                    .font(.caption)
                    .padding()
                    .accessibilityIdentifier("library.scan.progress")
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            viewportSize = AppleHomePageViewport.settled(drawn: viewportSize, measured: $0)
        }
        #if os(iOS)
        .onGeometryChange(for: EdgeInsets.self, of: AppleHeroSideBleed.sides) { sideInsets = $0 }
        .scrollClipDisabled(sideInsets != EdgeInsets())
        #endif
        #if os(iOS) || os(visionOS)
        .modifier(AppleDiscoverHeroLayoutReader(page: "library", phone: $phoneHeroLayout, pad: $padHeroLayout))
        #elseif os(macOS)
        .onScrollGeometryChange(for: AppleMacHeroLayout.self) { geometry in
            AppleMacHeroLayout(contentWidth: geometry.containerSize.width,
                               windowHeight: geometry.containerSize.height
                                   + geometry.contentInsets.top + geometry.contentInsets.bottom,
                               topInset: geometry.contentInsets.top)
        } action: { _, layout in
            macHeroLayout = layout
        }
        .appleMacHeroUnderToolbar()
        #endif
        #if os(tvOS)
        // The billboard runs under the top safe area (see Discover). No
        // Refresh on a TV home (X4); Sort sits on the first shelf's header
        // line (`sortAccessory`), so nothing floats over the art.
        .ignoresSafeArea(edges: .top)
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        #endif
        .refreshable { await reload() }
        .task { if library.groups.isEmpty && !library.isLoading { await reload() } }
        .task(id: "\(library.contentRevision)|\(progressRevision)") {
            let updated = await library.continueWatching(state: ApplePlaybackStore().readState())
            guard !Task.isCancelled else { return }
            continuing = updated
        }
        .onChange(of: library.progress) { _, _ in progressRevision &+= 1 }
        .onAppear {
            library.refreshProgress()
            AppleXtreamLibraryStore.shared.refreshProgress()
            progressRevision &+= 1
        }
    }
    private func reload() async {
        await library.reload(sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settings)
        await AppleXtreamLibraryStore.shared.reload(sourceStore: sourceStore, force: true)
    }
    private func shelf(_ title: String, _ groups: [AppleLibrarySeries], rowGroups: [AppleLibrarySeries]? = nil, progress: Bool = false,
                       accessory: AnyView? = nil, opensFullList: Bool = true) -> some View {
        AppleLocalTitleShelf(title: title, groups: groups, sourceStore: sourceStore,
            mediaIndex: mediaIndex, settings: settings, openSettings: openSettings, tabToolbar: titlePageToolbar,
            showsProgress: progress, accessory: accessory, opensFullList: opensFullList, rowGroups: rowGroups)
    }

    /// tvOS only: the Sort control as a bare glyph on the first shelf's header
    /// line. Other platforms keep it in the toolbar.
    private var sortAccessory: AnyView? {
        #if os(tvOS)
        AnyView(AppleTVLibrarySortButton(sort: $sort))
        #else
        nil
        #endif
    }
    private func detail(_ group: AppleLibrarySeries, autoPlay: Bool = false) -> some View {
        AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
            settings: settings, openSettings: openSettings, tabToolbar: titlePageToolbar, autoPlay: autoPlay)
    }

    /// Library's Search and Refresh for its title pages; Apple TV draws none.
    private var titlePageToolbar: AppleTabToolbarContext? {
        #if os(tvOS)
        nil
        #else
        tabToolbarContext
        #endif
    }

    #if !os(tvOS)
    private var libraryToolbarPlacement: ToolbarItemPlacement {
        #if os(visionOS)
        .bottomOrnament
        #else
        .primaryAction
        #endif
    }

    /// Library's Search and Refresh, for the pages pushed from here.
    private var tabToolbarContext: AppleTabToolbarContext {
        AppleTabToolbarContext(tab: .library, isRefreshing: { library.isLoading || AppleXtreamLibraryStore.shared.isLoading },
                               onSearch: { showsSearch = true }, onRefresh: { Task { await reload() } })
    }
    #endif
}
