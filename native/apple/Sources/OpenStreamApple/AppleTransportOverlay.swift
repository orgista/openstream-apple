import AVFoundation
import SwiftUI

/// Transport controls for decoded video surfaces and the full-screen Live player.
@MainActor
struct AppleTransportOverlay: View {
    struct SharePlayMenu {
        typealias Action = @MainActor () -> Void
        let primaryTitle: String
        let primaryAction: Action
        let secondaryTitle: String?
        let secondaryAction: Action?

        init(primaryTitle: String, primaryAction: @escaping Action, secondaryTitle: String? = nil, secondaryAction: Action? = nil) {
            self.primaryTitle = primaryTitle
            self.primaryAction = primaryAction
            self.secondaryTitle = secondaryTitle
            self.secondaryAction = secondaryAction
        }

        #if !os(macOS)
        @MainActor var uiMenu: UIMenu {
            var actions: [UIMenuElement] = [UIAction(title: primaryTitle) { _ in primaryAction() }]
            if let secondaryTitle, let secondaryAction {
                actions.append(UIAction(title: secondaryTitle, attributes: .destructive) { _ in secondaryAction() })
            }
            return UIMenu(title: "SharePlay", image: UIImage(systemName: "shareplay"), children: actions)
        }
        #endif
    }

    let coordinator: ApplePlaybackCoordinator
    let request: ApplePlaybackRequest
    let otherSources: (() -> Void)?
    let onZapChannel: ((AppleLiveZappingPolicy.Direction) -> Void)?
    let onLastChannel: (() -> Void)?
    let onShowChannels: (() -> Void)?
    let onPlaybackMenu: (() -> Void)?
    let playbackOptions: AppleLivePlaybackOptions?
    /// True while another surface — the live channel panel — is drawn over the
    /// player. `allowsHitTesting(false)` is not enough on its own: the clear
    /// full-screen "Show playback controls" button stays in the accessibility
    /// tree and is then the element found at every point over the panel, so
    /// VoiceOver read the surface instead of the channel rows and XCTest
    /// reported every visible row unhittable. `accessibilityHidden` did not
    /// remove the descendants either; the controls have to leave the
    /// hierarchy (2026-09-19).
    let isObscured: Bool
    let onBackgroundTap: ((_ wasHidden: Bool) -> Void)?
    let onControlsVisibilityChanged: ((Bool) -> Void)?
    let hideChromeSignal: Bool
    let onRequestFullScreen: (() -> Void)?
    let onClose: (() -> Void)?
    let sharePlayMenu: SharePlayMenu?
    /// Set while a programme plays from a channel's archive: a "Watch Live"
    /// control returns to the live channel.
    let onStartOver: (() -> Void)?
    let onWatchLive: (() -> Void)?
    /// iPhone/iPad Live: the chevrons' channel up/down.
    let onChannelStep: ((AppleLiveZappingPolicy.Direction) -> Void)?
    /// iPhone/iPad Live: the channel and programme above the scrubber.
    let nowPlaying: AppleLiveNowPlaying?
    /// iPhone/iPad Live: `pip.enter`, only while Picture in Picture can start.
    let onPictureInPicture: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var model: AppleTransportOverlayModel
    @State private var bottomBarHeight: CGFloat = 0
    /// The Next Episode card's height while it is up, so captions sit above
    /// it instead of under it (iPad v2 re-run).
    @State private var nextEpisodeCardHeight: CGFloat = 0
    /// Top edges of the bottom bar and the Next Episode card on screen
    /// (global space), so captions clear them whatever the letterboxing.
    @State private var bottomBarTop: CGFloat?
    @State private var nextEpisodeCardTop: CGFloat?
    @State private var isMuted = false

    /// Task 9: on Apple TV the surface overlay keeps only the scrubber and one
    /// captions control; the remote's buttons carry everything else.
    private let chrome = AppleTVPlaybackPresentationPolicy.surfaceChrome()

    /// The controls this overlay draws, from the same policy. The overlay is
    /// also owns Live chrome, which uses the same controls as the surface route.
    private var controls: [AppleTVPlaybackPresentationPolicy.SurfaceControl] {
        AppleTVPlaybackPresentationPolicy.visibleControls(
            route: .surface,
            isScrubbable: model.isScrubbable,
            hasOtherSources: true,
            hasSharePlay: sharePlayMenu != nil
        )
    }

    #if os(tvOS)
    fileprivate enum TVFocus: Hashable { case surface, scrubber, captions, nextEpisode, skipIntro, watchLive }
    @FocusState private var tvFocus: TVFocus?
    #endif

    init(
        coordinator: ApplePlaybackCoordinator,
        request: ApplePlaybackRequest,
        otherSources: (() -> Void)? = nil,
        onShowChannels: (() -> Void)? = nil,
        onZapChannel: ((AppleLiveZappingPolicy.Direction) -> Void)? = nil,
        onLastChannel: (() -> Void)? = nil,
        onStartOver: (() -> Void)? = nil,
        onPlaybackMenu: (() -> Void)? = nil,
        playbackOptions: AppleLivePlaybackOptions? = nil,
        isObscured: Bool = false,
        onBackgroundTap: ((_ wasHidden: Bool) -> Void)? = nil,
        onControlsVisibilityChanged: ((Bool) -> Void)? = nil,
        hideChromeSignal: Bool = false,
        onRequestFullScreen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        sharePlayMenu: SharePlayMenu? = nil,
        nextEpisode: AppleNextEpisodeContext? = nil,
        onWatchLive: (() -> Void)? = nil,
        onChannelStep: ((AppleLiveZappingPolicy.Direction) -> Void)? = nil,
        nowPlaying: AppleLiveNowPlaying? = nil,
        onPictureInPicture: (() -> Void)? = nil
    ) {
        self.onStartOver = onStartOver
        self.onWatchLive = onWatchLive
        self.onChannelStep = onChannelStep
        self.nowPlaying = nowPlaying
        self.onPictureInPicture = onPictureInPicture
        self.coordinator = coordinator
        self.request = request
        self.otherSources = otherSources
        self.onShowChannels = onShowChannels
        self.onZapChannel = onZapChannel
        self.onLastChannel = onLastChannel
        self.onPlaybackMenu = onPlaybackMenu
        self.playbackOptions = playbackOptions
        self.isObscured = isObscured
        self.onBackgroundTap = onBackgroundTap
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.hideChromeSignal = hideChromeSignal
        self.onRequestFullScreen = onRequestFullScreen
        self.onClose = onClose
        self.sharePlayMenu = sharePlayMenu
        let model = AppleTransportOverlayModel(
            coordinator: coordinator,
            isLive: request.isLive
        )
        if let nextEpisode {
            // The choices made in this episode go with it to the next.
            model.nextEpisode = { [weak model, coordinator] in
                let engine = coordinator.engine
                nextEpisode.start(AppleTrackCarryOver.capture(
                    audioTracks: engine.audioTracks,
                    activeAudioID: model?.selectedAudioID ?? engine.activeAudioTrackID,
                    subtitleTracks: engine.subtitleTracks,
                    activeSubtitleID: engine.activeSubtitleTrackID))
            }
            model.nextEpisodeTitle = nextEpisode.title
            model.autoPlayNextEpisode = UserDefaults.standard.object(
                forKey: AppleSettingsStore.autoPlayNextEpisodeKey) as? Bool ?? true
        }
        _model = State(initialValue: model)
    }

    #if os(tvOS)
    /// Draws exactly the label and nothing for focus: the playback surface's
    /// focus catcher must never paint over the video.
    private struct AppleTVSurfaceButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
    #endif

    var body: some View {
        ZStack {
            // `isObscured` is always false on tvOS, so the focus catcher below
            // never leaves the hierarchy there and the focus engine keeps its
            // target.
            if !isObscured {
                Button {
                    if onZapChannel != nil, let onShowChannels {
                        onShowChannels()
                    } else if chrome.selectTogglesPlayback {
                        model.togglePlayPause() 
                    } else { 
                        let wasHidden = !model.controlsVisible
                        model.bumpActivity()
                        onBackgroundTap?(wasHidden)
                    }
                } label: {
                    Color.clear.contentShape(.rect)
                }
                #if os(tvOS)
                // The stock plain style brightens and lifts a focused button; on a
                // full-screen clear label that is a light platter over the whole
                // picture (owner Y1: "washed out", inset rounded card).
                .buttonStyle(AppleTVSurfaceButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .appleHoverAffordance()
                .accessibilityLabel(chrome.selectTogglesPlayback ? "Play or pause" : "Show playback controls")
                .accessibilityValue(onZapChannel == nil ? "" : request.title ?? "")
                .accessibilityIdentifier(onZapChannel == nil ? "player.controls.show" : "live.player.surface")
                #if os(tvOS)
                .focused($tvFocus, equals: .surface)
                .contextMenu {
                    if let playbackOptions { playbackOptions }
                    else if let onPlaybackMenu { Button("Playback Options", action: onPlaybackMenu) }
                }
                .onMoveCommand { direction in
                    // The surface holds focus while the video plays, so the
                    // clickpad edges skip and a swipe down reveals the controls.
                    switch direction {
                    case .left where model.canSkip: Task { await model.skip(by: -chrome.moveSkipSeconds) }
                    case .right where model.canSkip: Task { await model.skip(by: chrome.moveSkipSeconds) }
                    case .up where onZapChannel != nil: onZapChannel?(.next)
                    case .down where onZapChannel != nil: onZapChannel?(.previous)
                    case .up where onPlaybackMenu != nil: onPlaybackMenu?()
                    case .down where onShowChannels != nil: onShowChannels?()
                    case .down:
                        model.bumpActivity()
                        if model.nextEpisodePrompt != nil {
                            tvFocus = .nextEpisode
                        } else if model.showsSkipIntro {
                            // Hidden chrome is not a geometric target, so the
                            // reveal and the focus write share this update,
                            // as the scrubber's does.
                            tvFocus = .skipIntro
                        } else if onWatchLive != nil {
                            // Over an archived programme the way back to the
                            // channel is the first stop. Kept a focus target
                            // while faded, exactly like Skip Intro: a control
                            // inside the chrome's opacity-0 fade is not, and
                            // the write was dropped (Apple TV, 2026-10-02).
                            tvFocus = .watchLive
                        } else {
                            tvFocus = model.isScrubbable ? .scrubber : .captions
                        }
                    default: model.bumpActivity()
                    }
                }
                #endif
            }

            #if os(tvOS)
            // The focus engine needs the chrome mounted: a swipe down sets
            // `tvFocus` in the same update that reveals it.
            if onZapChannel == nil {
                transportChrome
                .opacity(model.controlsVisible ? 1 : 0)
                .allowsHitTesting(model.controlsVisible)
                .accessibilityHidden(!model.controlsVisible)
            }
            #else
            // Removed, not faded. Fading it left every button on screen as far
            // as touch and assistive technology were concerned: after the
            // three-second auto-hide, "Channels" was still reported at full
            // size, still hittable, and `allowsHitTesting(false)` silently
            // swallowed the tap — so the picker never opened and the tap never
            // reached the reveal surface underneath either (2026-09-18).
            if model.controlsVisible, !isObscured {
                #if os(iOS)
                if usesLiveSystemChrome {
                    liveSystemChrome.transition(.opacity)
                } else {
                    transportChrome.transition(.opacity)
                }
                #else
                transportChrome.transition(.opacity)
                #endif
            }
            #endif

            // Inside the chrome's fade: the transport auto-hides
            // after three seconds of playback, so these prompts follow
            // the same visibility as the rest of the controls.
            VStack {
                Spacer()
                HStack {
                    #if os(tvOS)
                    watchLiveButton
                        .opacity(model.controlsVisible ? 1 : AppleTVSkipIntroFocusPolicy.hiddenOpacity)
                    #else
                    if model.controlsVisible { watchLiveButton.transition(.opacity) }
                    #endif
                    Spacer()
                    #if os(tvOS)
                    // Faded with the controls but still a focus target, so a
                    // Down on the picture with the controls hidden can move
                    // here in the same update that reveals them. At opacity 0
                    // it left the focus chain and the write was dropped
                    // (Apple TV verification 2026-10-01). Being a focus
                    // target, it stays an accessibility element too.
                    skipIntroButton
                        .opacity(model.controlsVisible ? 1 : AppleTVSkipIntroFocusPolicy.hiddenOpacity)
                    #else
                    if model.controlsVisible { skipIntroButton.transition(.opacity) }
                    #endif
                }
                HStack {
                    Spacer()
                    nextEpisodeCard
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { nextEpisodeCardHeight = $0 }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).minY
                        } action: { nextEpisodeCardTop = $0 }
                }
            }
            .padding(nextEpisodeCardInset)
            // Reserve the real control height, including Dynamic Type, so
            // prompts cannot cover captions or the scrubber. Keep this space
            // when the controls fade to avoid moving the button mid-tap.
            .padding(.bottom, bottomBarHeight + AppleDesignTokens.spacingMedium)

            if model.showsWaitingIndicator { waitingIndicator }
            // Cues sit against the **picture**, not the screen; the same
            // layer is mounted over the stock player on `.avPlayer`.
            // With the bar measured on screen, the cue clears its real top
            // edge (`clearance`); the height sum is the fallback before the
            // first layout pass.
            AppleSubtitleCueLayer(cues: model.activeSubtitleCues, videoSize: coordinator.engine.videoSize,
                                  textBottomLift: bottomBarTop == nil
                                      ? AppleSubtitleCueLift.lift(
                                          controlsVisible: model.controlsVisible, bottomBarHeight: bottomBarHeight,
                                          promptTop: model.nextEpisodePrompt == nil ? 0
                                              : bottomBarHeight + AppleDesignTokens.spacingMedium
                                                  + nextEpisodeCardInset + nextEpisodeCardHeight)
                                      : AppleSubtitleCueLift.hidden,
                                  controlsTop: model.controlsVisible ? bottomBarTop : nil,
                                  promptTop: model.nextEpisodePrompt == nil ? nil : nextEpisodeCardTop)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: request.mediaID) {
            // The coordinator's route is not available through `init`, so the
            // view seeds the model here. The DVR window is NOT seeded from the
            // request: `effectiveDVRWindowSeconds` is the engine's retention
            // hint (1800 for every live channel), and the transport reads the
            // player's real seekable range instead — see `liveSeekableRange`.
            model.route = coordinator.route
        }
        .onChange(of: coordinator.engine.avPlayer.map(ObjectIdentifier.init), initial: true) { _, _ in
            isMuted = coordinator.engine.avPlayer?.isMuted ?? false
        }
        .onChange(of: coordinator.phase) { _, _ in model.playbackPhaseChanged() }
        .onChange(of: coordinator.route) { _, newRoute in
            model.route = newRoute
        }
        #if os(tvOS)
        .defaultFocus($tvFocus, .surface)
        .onChange(of: model.controlsVisible) { _, isVisible in
            onControlsVisibilityChanged?(isVisible)
            // Focus returns to the invisible surface when the controls hide,
            // so nothing is drawn as focused during playback.
            if AppleTVSkipIntroFocusPolicy.returnsFocusToSurfaceOnHide(
                isVisible: isVisible,
                hidesFocusDuringPlayback: chrome.hidesFocusDuringPlayback,
                skipIntroIsFocused: tvFocus == .skipIntro
            ) { tvFocus = .surface }
        }
        .onChange(of: tvFocus) { old, new in
            #if DEBUG
            AppleInteractionTrace.record(.focus, "overlay \(new.map(String.init(describing:)) ?? "none")")
            #endif
            // The player opens with nothing focused and the engine's first
            // pick is Skip Intro, not the picture (`defaultFocus` is not
            // consulted). Only the viewer's own move should land there.
            if AppleTVSkipIntroFocusPolicy.returnsInitialFocusToSurface(
                cameFromNowhere: old == nil, landedOnSkipIntro: new == .skipIntro
            ) || (old == nil && new == .watchLive) {
                tvFocus = .surface
                return
            }
            // A focused Skip Intro holds the controls up: the three-second
            // auto-hide took the focus back to the picture a moment after it
            // landed (Apple TV verification 2026-10-01).
            model.focusedPromptHoldsControls = new == .skipIntro
        }
        .onPlayPauseCommand { model.togglePlayPause() }
        .onExitCommand {
            // Menu closes the player and returns to the page that opened it.
            if let onClose { onClose() } else { dismiss() }
        }
        #endif
    }

    /// The auto-hiding controls: top bar, centre transport, bottom bar. A tap
    /// anywhere inside them restarts the hide timer instead of hiding them.
    private var transportChrome: some View {
        VStack {
            topBar
            Spacer()
            // No play/pause or skip glyphs on Apple TV: Select, the
            // Play/Pause button and the clickpad edges carry them.
            // Not while waiting: the spinner is in the middle then, and a
            // Play glyph over a stalled live frame read as "paused".
            if chrome.showsPlayPauseGlyph, !model.showsWaitingIndicator { centerRow }
            Spacer()
            bottomBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    bottomBarHeight = $0
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    bottomBarTop = $0
                }
        }
        .padding()
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { model.bumpActivity() })
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if controls.contains(.close) {
                Button {
                    if let onRequestFullScreen { onRequestFullScreen() }
                    else if let onClose { onClose() }
                    else {
                        coordinator.stop()
                        dismiss()
                    }
                } label: {
                    Image(systemName: onRequestFullScreen == nil ? "xmark" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                        .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .appleHoverAffordance()
                .accessibilityLabel(onRequestFullScreen == nil ? "Close player" : "Full Screen")
                .accessibilityIdentifier(onRequestFullScreen == nil ? "player.close" : "player.fullscreen")
            }

            if let onShowChannels {
                Button {
                    model.bumpActivity()
                    onShowChannels()
                } label: {
                    Text("Channels")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.channels")
            }
            if let onLastChannel {
                Button("Last Channel", action: onLastChannel)
                    .buttonStyle(.plain)
                    .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                    .accessibilityIdentifier("live.player.lastChannel")
            }
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if liveTopControls {
                    AppleTransportTrackMenu(
                        audioTracks: model.audioTracks,
                        selectedAudioID: model.selectedAudioID,
                        subtitleTracks: model.subtitleTracks,
                        preferredSubtitleLanguages: model.preferredSubtitleLanguages,
                        selectedSubtitleID: model.selectedSubtitleID,
                        onSelectAudio: { model.selectAudio($0) },
                        onSelectSubtitle: { model.selectSubtitle($0) },
                        subtitleTiming: model.subtitleTiming,
                        onChangeSubtitleTiming: { model.changeSubtitleTiming($0) },
                        onMenuItemAppeared: { model.menuItemAppeared() },
                        onMenuItemDisappeared: { model.menuItemDisappeared() }
                    )
                }
                if controls.contains(.otherSourcesMenu) {
                    Menu {
                        if let onStartOver {
                            Button("Start Over", action: onStartOver)
                                .appleMenuPresence(model)
                                .accessibilityIdentifier("live.player.startOver")
                        }
                        if let onWatchLive {
                            Button("Back to Live", action: onWatchLive)
                                .appleMenuPresence(model)
                                .accessibilityIdentifier("live.player.backToLive")
                        }
                        AppleSleepTimerMenu(coordinator: coordinator, isLive: request.isLive, transport: model)
                        if !model.chapters.isEmpty {
                            Menu("Chapters", systemImage: "list.bullet") {
                                ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, chapter in
                                    Button {
                                        Task { await model.jump(to: chapter) }
                                    } label: {
                                        Text(chapter.title)
                                        Text(AppleTransportOverlayModel.timeText(chapter.start))
                                    }
                                    .appleMenuPresence(model)
                                }
                            }
                            .appleMenuPresence(model)
                            .accessibilityIdentifier("player.chapters")
                        }
                        if let otherSources {
                            Button("Quality", systemImage: "slider.horizontal.3", action: otherSources)
                                .appleMenuPresence(model)
                                .accessibilityIdentifier("player.quality")
                        }
                        if liveTopControls, let sharePlayMenu, controls.contains(.sharePlayMenu) {
                            Button(sharePlayMenu.primaryTitle, action: sharePlayMenu.primaryAction)
                            if let title = sharePlayMenu.secondaryTitle, let action = sharePlayMenu.secondaryAction {
                                Button(title, role: .destructive, action: action)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                            .contentShape(.rect)
                    }
                    .appleBareMenu()
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("player.options")
                }
                if let sharePlayMenu, controls.contains(.sharePlayMenu),
                   !liveTopControls || !controls.contains(.otherSourcesMenu) {
                    Menu {
                        Button(sharePlayMenu.primaryTitle, action: sharePlayMenu.primaryAction)
                        if let secondaryTitle = sharePlayMenu.secondaryTitle, let secondaryAction = sharePlayMenu.secondaryAction {
                            Button(secondaryTitle, role: .destructive, action: secondaryAction)
                        }
                    } label: {
                        Image(systemName: liveTopControls ? "ellipsis" : "shareplay").frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                            .contentShape(.rect)
                    }
                    .appleBareMenu()
                    .accessibilityLabel(liveTopControls ? "More" : "SharePlay")
                    .accessibilityIdentifier("player.more")
                }
                if liveTopControls, let player = coordinator.engine.avPlayer {
                    Button {
                        player.isMuted.toggle()
                        isMuted = player.isMuted
                        model.bumpActivity()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isMuted ? "Unmute" : "Mute")
                    .accessibilityIdentifier("player.mute")
                }
            }
            if request.isLive, !liveTopControls {
                liveBadge
            }

        }
    }

    #if os(iOS)
    /// iPhone and iPad Live take the system player's layout
    /// (`AppleLiveSystemChrome`); VOD, tvOS and visionOS keep this one.
    private var usesLiveSystemChrome: Bool { request.isLive }

    private var liveSystemChrome: some View {
        ZStack {
            // One flat 35 % dim while the chrome is up, as the system player
            // draws it; a tap on it (not on a control) hides the chrome.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { model.hideControls() }
                .accessibilityHidden(true)
            AppleLiveSystemChrome(
                model: model,
                coordinator: coordinator,
                request: request,
                isMuted: isMuted,
                onToggleMute: coordinator.engine.avPlayer == nil ? nil : {
                    guard let player = coordinator.engine.avPlayer else { return }
                    player.isMuted.toggle()
                    isMuted = player.isMuted
                    model.bumpActivity()
                },
                nowPlaying: nowPlaying,
                onClose: {
                    if let onClose { onClose() } else {
                        coordinator.stop()
                        dismiss()
                    }
                },
                onPictureInPicture: onPictureInPicture,
                onLastChannel: onLastChannel,
                onStartOver: onStartOver,
                onShowChannels: onShowChannels,
                onChannelStep: onChannelStep,
                sharePlayMenu: sharePlayMenu
            )
        }
        .simultaneousGesture(TapGesture().onEnded { if model.controlsVisible { model.bumpActivity() } })
    }
    #endif

    private var liveTopControls: Bool {
        #if os(iOS) || os(visionOS)
        request.isLive
        #else
        false
        #endif
    }

    @ViewBuilder
    private var liveBadge: some View {
        if model.isScrubbable {
            // live with DVR: badge is tappable → seek to live edge.
            Button {
                Task { await model.seekToLiveEdge() }
            } label: {
                liveBadgeLabel
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Live")
            .accessibilityValue(model.isAtLiveEdge ? "At the live edge" : "Behind live")
            .accessibilityIdentifier("player.live")
            #if os(tvOS)
            .focusable()
            #endif
        } else {
            liveBadgeLabel
        }
    }

    private var liveBadgeLabel: some View {
        // Red while the stream is at its edge, plain once the viewer has
        // scrubbed back into the DVR window — the same way the TV app's LIVE
        // pill behaves, and the only thing on the screen that says a ten
        // second skip did anything.
        Text("LIVE")
            .font(.caption)
            .bold()
            .foregroundStyle(model.isAtLiveEdge ? Color.red : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: - Waiting indicator

    /// A centered spinning circle — no text, no background box, no border.
    /// The coordinator's waiting message is exposed only as an accessibility
    /// label.
    private var waitingIndicator: some View {
        VStack(spacing: AppleDesignTokens.spacingMedium) {
            if request.hints.disc != nil {
                // A disc item opens with the disc turning.
                AppleDiscSpinner(size: 36)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .controlSize(.large)
            }
            // A stalled live channel says it is coming back.
            if model.showsReconnecting {
                Text("Reconnecting…")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .appleTransportGlyphLegibility()
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.showsReconnecting ? "Reconnecting" : model.waitingText)
    }

    // MARK: - Skip intro

    /// Offered only while the position is inside a chapter the stream itself
    /// names as its opening. Sits on the same column and layer as the
    /// end-of-episode card, and for the same reason: it must not disappear
    /// with the auto-hiding transport while it is the thing to act on.
    @ViewBuilder
    private var skipIntroButton: some View {
        if model.showsSkipIntro {
            Button("Skip Intro") { Task { await model.skipIntro() } }
                .buttonStyle(.brandSecondary)
                #if os(tvOS)
                .focused($tvFocus, equals: .skipIntro)
                .onDisappear {
                    if tvFocus == .skipIntro { tvFocus = .surface }
                }
                #endif
                .accessibilityIdentifier("player.skipIntro")
                .transition(.opacity)
        }
    }

    /// Back to the live channel from a programme played out of the archive.
    /// Same pill and the same faded-focus rule as Skip Intro.
    @ViewBuilder
    private var watchLiveButton: some View {
        if let onWatchLive {
            Button("Back to Live") {
                #if DEBUG
                AppleInteractionTrace.record(.press, "player watch live")
                #endif
                onWatchLive()
            }
            .buttonStyle(.brandSecondary)
            #if os(tvOS)
            .focused($tvFocus, equals: .watchLive)
            .onDisappear {
                if tvFocus == .watchLive { tvFocus = .surface }
            }
            #endif
            .accessibilityIdentifier("player.watchLive")
            .transition(.opacity)
        }
    }

    // MARK: - Next episode

    /// The card sits on the same column as the rest of the app. tvOS already
    /// insets the overlay by the safe area, so only the remainder is needed
    /// here; other platforms keep the standard large inset.
    private var nextEpisodeCardInset: CGFloat {
        #if os(tvOS)
        AppleTVChromeMetrics.glyphPairTrailingPaddingInsideSafeArea
        #else
        AppleDesignTokens.spacingLarge
        #endif
    }

    /// The end-of-episode card: the next episode's name, a Play pill that
    /// carries the countdown, and a way out.
    ///
    /// It is a card rather than a transport button on purpose — the Apple TV
    /// overlay is deliberately a scrubber and one captions control, and a
    /// permanent Next Episode button would undo that.
    @ViewBuilder
    private var nextEpisodeCard: some View {
        if let prompt = model.nextEpisodePrompt {
            VStack(alignment: .leading, spacing: AppleDesignTokens.spacingMedium) {
                Text(prompt.title)
                    #if os(tvOS)
                    .font(.system(size: AppleTVGuideMetrics.standard.titleFontSize, weight: .semibold))
                    #else
                    .font(.headline)
                    #endif
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Button(prompt.countdownLabel) { model.playNextEpisode() }
                        .buttonStyle(.brandPrimary)
                        #if os(tvOS)
                        .focused($tvFocus, equals: .nextEpisode)
                        #endif
                        .accessibilityIdentifier("player.nextEpisode.play")
                    Button("Not Now") { model.dismissNextEpisode() }
                        .buttonStyle(.brandSecondary)
                        .accessibilityIdentifier("player.nextEpisode.dismiss")
                }
            }
            // The app's own tokens rather than one-off numbers: the surface
            // colour every card uses and the card corner radius. A 0.75 black
            // panel with a 16 pt radius was this card's alone and read as a
            // foreign object over the picture.
            .padding(AppleDesignTokens.spacingLarge)
            .background(
                AppleDesignTokens.surface.opacity(0.94),
                in: .rect(cornerRadius: AppleDesignTokens.cornerRadiusCard, style: .continuous)
            )
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            #if os(tvOS)
            // The card is the thing to act on while it is up, so focus lands
            // there rather than leaving the remote on the scrubber.
            .onAppear { tvFocus = .nextEpisode }
            .onDisappear {
                if tvFocus == .nextEpisode { tvFocus = .surface }
            }
            #endif
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if controls.contains(.scrubber) {
                #if os(tvOS)
                AppleTransportScrubberRow(
                    model: model,
                    height: chrome.scrubberHeight,
                    tvFocus: $tvFocus,
                    // Reach the chapter action above the scrubber when it is
                    // present; otherwise keep focus on a visible control.
                    onMoveUp: { tvFocus = model.showsSkipIntro ? .skipIntro : (onWatchLive != nil ? .watchLive : (controls.contains(.captions) ? .captions : .surface)) },
                    onMoveDown: { tvFocus = controls.contains(.captions) ? .captions : .surface }
                )
                #else
                AppleTransportScrubberRow(model: model, height: chrome.scrubberHeight)
                #endif
            }
            HStack {
                if liveTopControls { liveBadge }
                Spacer()
                if controls.contains(.captions), !liveTopControls {
                    // One captions control, as in the Apple TV app: the menu
                    // holds Off, every track and the audio languages.
                    // Every track, not `menuSubtitleTracks`: the menu splits
                    // them into the viewer's languages and "More…", which the
                    // filtered list left empty (Apple TV verification 2026-10-01).
                    AppleTransportTrackMenu(
                        audioTracks: model.audioTracks,
                        selectedAudioID: model.selectedAudioID,
                        subtitleTracks: model.subtitleTracks,
                        preferredSubtitleLanguages: model.preferredSubtitleLanguages,
                        selectedSubtitleID: model.selectedSubtitleID,
                        onSelectAudio: { model.selectAudio($0) },
                        onSelectSubtitle: { model.selectSubtitle($0) },
                        subtitleTiming: model.subtitleTiming,
                        onChangeSubtitleTiming: { model.changeSubtitleTiming($0) },
                        onMenuItemAppeared: { model.menuItemAppeared() },
                        onMenuItemDisappeared: { model.menuItemDisappeared() }
                    )
                    #if os(tvOS)
                    .focused($tvFocus, equals: .captions)
                    #endif
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Big centered play/pause flanked by 10 s skip buttons.
    private var centerRow: some View {
        HStack(spacing: 48) {
            // No ±10 s on live: the LIVE scrubber is how a channel rewinds.
            if model.canSkip, !model.isLive { skipButton(seconds: -10, systemName: "gobackward.10") }
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .appleTransportGlyphLegibility()
                    .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .appleHoverAffordance()
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .appleVisionActionTarget()
            .accessibilityIdentifier("player.play-pause")
            #if os(tvOS)
            .focusable()
            #endif

            if model.canSkip, !model.isLive { skipButton(seconds: 10, systemName: "goforward.10") }
        }
    }

    @ViewBuilder
    private func skipButton(seconds: Double, systemName: String) -> some View {
        Button {
            Task { await model.skip(by: seconds) }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .appleTransportGlyphLegibility()
                .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
            .appleHoverAffordance()
        .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
        .accessibilityIdentifier(seconds < 0 ? "player.skip-back" : "player.skip-forward")
        #if os(tvOS)
        .focusable()
        #endif
    }

    // MARK: - Helpers

    private var isPlaying: Bool {
        if case .playing = coordinator.phase { return true }
        return false
    }
}

/// The scrubber row (position text, slider/bar, remaining time). Extracted so
/// its Observation tracking is scoped to `position`/`progress`/`duration`
/// only, keeping sibling controls (e.g. the track menu) from being
/// re-evaluated on every position tick.
@MainActor
private struct AppleTransportScrubberRow: View {
    let model: AppleTransportOverlayModel
    let height: CGFloat
    #if os(tvOS)
    let tvFocus: FocusState<AppleTransportOverlay.TVFocus?>.Binding
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    #endif

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 12) {
            positionLabel
            tvosScrubber
            remainingLabel
        }
        #else
        // At the accessibility sizes the times took most of the row and
        // squeezed the scrubber to a stub (iPhone 27 v2 re-run, AX-XXXL):
        // there the scrubber gets the full width and the times a row under it.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 4) {
                slider
                HStack {
                    positionLabel
                    Spacer(minLength: 12)
                    remainingLabel
                }
            }
        } else {
            HStack(spacing: 12) {
                positionLabel
                slider
                remainingLabel
            }
        }
        #endif
    }

    private var positionLabel: some View {
        Text(model.positionText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .appleTransportGlyphLegibility()
    }

    private var remainingLabel: some View {
        Text(remainingText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .appleTransportGlyphLegibility()
    }

    #if !os(tvOS)
    private var slider: some View {
        Slider(value: Binding(
            get: { model.progress },
            set: { fraction in Task { await model.scrub(to: fraction) } }
        ), in: 0...1)
        .tint(.white)
        .overlay { chapterMarks(height: 10) }
        .appleVisionActionTarget()
        .accessibilityLabel("Playback position")
        .accessibilityValue(model.positionText)
    }
    #endif

    /// A thin mark at each chapter start, as in the Apple TV app's scrubber.
    /// Drawn over the track and never hit-tested, so scrubbing is unchanged.
    private func chapterMarks(height: CGFloat) -> some View {
        GeometryReader { proxy in
            ForEach(model.chapterMarkFractions, id: \.self) { fraction in
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: 2, height: height)
                    .position(x: proxy.size.width * fraction, y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Remaining time as `-m:ss` (or `-h:mm:ss`). Empty for live.
    private var remainingText: String {
        if model.isLive { return "" }
        guard let duration = model.duration, duration > 0 else { return "" }
        let remaining = max(0, duration - model.position)
        return "-" + AppleTransportOverlayModel.timeText(remaining)
    }

    #if os(tvOS)
    /// `Slider` is unavailable on tvOS, so the scrubber is a focusable bar
    /// driven by the remote's left/right `onMoveCommand`.
    private var tvosScrubber: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(tvFocus.wrappedValue == .scrubber ? 0.45 : 0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * model.progress)
                chapterMarks(height: height)
            }
            .frame(height: height)
            // Stands down while Skip Intro is offered, so Down from the
            // picture cannot land on it first (Apple TV verification
            // 2026-10-01). Captions stays reachable below Skip Intro.
            .focusable(AppleTVSkipIntroFocusPolicy.scrubberIsFocusable(showsSkipIntro: model.showsSkipIntro))
            .focused(tvFocus, equals: .scrubber)
            .onMoveCommand { direction in
                switch direction {
                case .left: Task { await model.scrub(to: model.progress - 0.05) }
                case .right: Task { await model.scrub(to: model.progress + 0.05) }
                case .up: onMoveUp()
                case .down: onMoveDown()
                @unknown default: break
                }
            }
        }
        .frame(height: height)
    }
    #endif
}

/// The single captions control: an "Audio & Subtitles" menu grouping the
/// audio track choices and the subtitle (Off + tracks) choices, like the
/// Apple TV app's. A separate CC key beside it made two captions controls
/// (N42); the bubble fills while a subtitle is on instead. Extracted
/// into its own view so its Observation tracking depends only on the track
/// arrays passed in, not on the overlay's per-tick position state — an open
/// `Menu` inside a view that also reads `position` gets torn down and
/// rebuilt on every position update, which flashes the menu and drops taps.
@MainActor
struct AppleTransportTrackMenu: View {
    let audioTracks: [ApplePlaybackTrack]
    var selectedAudioID: Int? = nil
    let subtitleTracks: [ApplePlaybackTrack]
    let preferredSubtitleLanguages: [String]
    let selectedSubtitleID: Int?
    let onSelectAudio: (Int) -> Void
    let onSelectSubtitle: (Int?) -> Void
    /// The per-play subtitle delay and frame-rate fix; the rows show only
    /// while a subtitle is on and a handler is given.
    var subtitleTiming = AppleSubtitleTiming()
    var onChangeSubtitleTiming: ((AppleSubtitleTiming.Change) -> Void)? = nil
    /// Each row reports itself so the chrome stays up while the menu is open.
    var onMenuItemAppeared: () -> Void = {}
    var onMenuItemDisappeared: () -> Void = {}

    var body: some View {
        Menu {
            let audio = AppleAudioTrackMenu.entries(audioTracks, activeTrackID: selectedAudioID)
            if audio.count > 1 {
                Section("Audio") {
                    ForEach(audio) { entry in
                        Button { onSelectAudio(entry.trackID) } label: {
                            if entry.isSelected {
                                Label(entry.title, systemImage: "checkmark")
                            } else {
                                Text(entry.title)
                            }
                        }
                        .accessibilityLabel(entry.title)
                        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
                        .accessibilityIdentifier("player.audio.track.\(entry.id)")
                        .onAppear(perform: onMenuItemAppeared)
                        .onDisappear(perform: onMenuItemDisappeared)
                    }
                }
            }
            Section("Subtitles") {
                ForEach(AppleSubtitleCueLayerPolicy.menuEntries(
                    tracks: subtitleTracks, preferredLanguages: preferredSubtitleLanguages,
                    languagesAreExplicit: false, activeTrackID: selectedSubtitleID
                )) { entry in
                    subtitleButton(entry)
                }
                let more = AppleSubtitleCueLayerPolicy.moreMenuEntries(
                    tracks: subtitleTracks, preferredLanguages: preferredSubtitleLanguages,
                    activeTrackID: selectedSubtitleID)
                if !more.isEmpty {
                    Menu(AppleSubtitleCueLayerPolicy.moreMenuTitle) {
                        ForEach(more) { entry in
                            subtitleButton(entry)
                        }
                    }
                    .accessibilityIdentifier("player.subtitle.more")
                    .onAppear(perform: onMenuItemAppeared)
                    .onDisappear(perform: onMenuItemDisappeared)
                }
                if let onChangeSubtitleTiming,
                   AppleSubtitleTimingMenu.isOffered(subtitleSelected: selectedSubtitleID != nil) {
                    AppleSubtitleTimingMenus(timing: subtitleTiming, change: onChangeSubtitleTiming,
                                             onItemAppeared: onMenuItemAppeared,
                                             onItemDisappeared: onMenuItemDisappeared)
                }
            }
        } label: {
            Image(systemName: selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 22))
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                .contentShape(.rect)
                #if !os(tvOS)
                .foregroundStyle(.white)
                #endif
                // tvOS: `AppleTVGlyphStyle` colours the glyph, black on its
                // white focus disc; a fixed white drew a blank disc.
        }
        .appleBareMenu()
        .accessibilityLabel("Audio & Subtitles")
        .accessibilityValue(selectedSubtitleID == nil ? "Subtitles off" : "Subtitles on")
        .accessibilityIdentifier("player.captions")
        #if os(tvOS)
        // A `.focusable()` wrapper used to take the focus and swallow Select,
        // so the menu never opened (owner 16:27). The menu is focusable on its
        // own; a bare glyph disc replaces the stock boxed button.
        .menuStyle(.button)
        .buttonStyle(AppleTVGlyphStyle())
        #endif
    }

    private func subtitleButton(_ entry: AppleSubtitleCueLayerPolicy.MenuEntry) -> some View {
        Button { onSelectSubtitle(entry.trackID) } label: {
            if entry.isSelected {
                Label(entry.title, systemImage: "checkmark")
            } else {
                Text(entry.title)
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
        .accessibilityIdentifier("player.subtitle.track.\(entry.id)")
        .onAppear(perform: onMenuItemAppeared)
        .onDisappear(perform: onMenuItemDisappeared)
    }
}

private extension View {
    /// A row of a transport menu: holds the auto-hide while it is on screen.
    func appleMenuPresence(_ model: AppleTransportOverlayModel) -> some View {
        onAppear { model.menuItemAppeared() }
            .onDisappear { model.menuItemDisappeared() }
    }
}

/// Down from the picture reaches Skip Intro before the scrubber row while it
/// is offered, and the auto-hide never takes the focus off it.
enum AppleTVSkipIntroFocusPolicy {
    /// Skip Intro's opacity while the controls are hidden: invisible over the
    /// picture, yet above the focus engine's cut-off (about 0.01), below
    /// which a view cannot take focus.
    static let hiddenOpacity: Double = 0.02

    /// The scrubber row is not a focus target while Skip Intro is offered.
    static func scrubberIsFocusable(showsSkipIntro: Bool) -> Bool {
        !showsSkipIntro
    }

    /// Focus that lands on Skip Intro from nowhere is the focus engine's
    /// first pick as the player opens, not the viewer's: it goes to the
    /// picture, so the controls can hide.
    static func returnsInitialFocusToSurface(cameFromNowhere: Bool, landedOnSkipIntro: Bool) -> Bool {
        cameFromNowhere && landedOnSkipIntro
    }

    /// Whether hiding the controls hands the focus back to the picture.
    static func returnsFocusToSurfaceOnHide(isVisible: Bool, hidesFocusDuringPlayback: Bool,
                                            skipIntroIsFocused: Bool) -> Bool {
        !isVisible && hidesFocusDuringPlayback && !skipIntroIsFocused
    }
}

/// How far text cues rise above the bottom of the picture.
///
/// A fixed 100 pt cleared the phone's controls, but the Apple TV's scrubber
/// row is taller and the cue was drawn across the scrubber line (full test
/// 2026-10-01). While the controls show, the cue clears the measured bottom
/// bar plus a gap; hidden, it rests near the bottom.
extension View {
    /// A soft shadow on a transport glyph or time, so it stays readable over
    /// bright video (iPad v2 re-run: icons vanished over a light frame). On
    /// the glyph only: no scrim or gradient over the picture (AGENTS.md §4).
    func appleTransportGlyphLegibility() -> some View {
        shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
    }
}

enum AppleSubtitleCueLift {
    static let hidden: CGFloat = 24
    static let minimumVisible: CGFloat = 100
    static let gapAboveControls: CGFloat = 40

    /// The gap between a caption and a card drawn under it.
    static let gapAbovePrompt: CGFloat = 12

    /// `promptTop` is how far above the bottom the Next Episode card's top
    /// edge sits, or 0 with no card. Captions clear it whether or not the
    /// controls are showing.
    static func lift(controlsVisible: Bool, bottomBarHeight: CGFloat, promptTop: CGFloat = 0) -> CGFloat {
        let base = controlsVisible ? max(minimumVisible, bottomBarHeight + gapAboveControls) : hidden
        return promptTop > 0 ? max(base, promptTop + gapAbovePrompt) : base
    }

    /// How far a text cue must rise inside a layer whose bottom edge is at
    /// `layerBottom` to clear the controls and the Next Episode card, all in
    /// one (global) coordinate space. Measured against the screen, not the
    /// picture: a letterboxed 2.39:1 movie used to put the cue on the
    /// scrubber line because the lift was added to a video-rect inset worked
    /// out in a different frame (Apple TV regression 2026-10-01).
    /// `nil` means that obstacle is not on screen.
    static func clearance(layerBottom: CGFloat, controlsTop: CGFloat?, promptTop: CGFloat?) -> CGFloat {
        var rise: CGFloat = 0
        if let controlsTop { rise = max(rise, layerBottom - controlsTop + gapAboveControls) }
        if let promptTop { rise = max(rise, layerBottom - promptTop + gapAbovePrompt) }
        return rise
    }
}
