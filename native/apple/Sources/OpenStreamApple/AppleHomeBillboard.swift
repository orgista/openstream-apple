import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
import Combine
#endif

/// Discover's home hero. Every platform draws the same composition —
/// `AppleFeaturedHero`: art edge to edge, the app's one fade, the wordmark
/// lockup with genre/year, a two-line synopsis, Play and Details, and the
/// rotation dots, all anchored bottom-leading over the art, with the first row
/// peeking in underneath.
///
/// This view supplies the inline trailer stage and the shared title-page
/// primary action, so every hero layout agrees on what its button will do.
/// The Apple TV's stage is the still alone: it plays no trailer and looks
/// none up (`AppleTitlePagePolicy.offersTrailers`).
/// A stacked card lived here between 2026-09-18
/// and 2026-09-20 and was the iPad landscape regression the owner reported: the
/// art was capped at a flat 600 pt, the wordmark sat below it at a flat 90 pt,
/// and Play/Details were pushed off the bottom of the screen.
struct AppleHomeBillboard<Actions: View>: View {
    let item: AppleCatalogItem
    let sources: [AppleSource]
    let progressID: String
    let preferredSourceID: AppleSource.ID
    let onPlay: () -> Void
    /// Opens the title page: the button's action when nothing here plays.
    let onOpenDetails: () -> Void
    let settings: AppleSettingsStore
    let viewportSize: CGSize
    let wordmark: URL?
    /// The hero's wordmark lookup has not finished yet (`AppleHeroTitleLockup`);
    /// `nil` for a hero that does not track it.
    var wordmarkLookupPending: Bool? = nil
    let rotationCount: Int
    let rotationIndex: Int
    /// Set on an iPhone in portrait: draw the Apple TV app's hero
    /// (`AppleHomePhoneHero`) over the same stage instead of the featured one.
    var phone: Phone? = nil
    /// Set on the Mac and on the iPad's Discover: draw the Apple TV app's
    /// full-bleed hero (`AppleHomeMacHero`) over the same stage.
    var mac: Mac? = nil
    /// Set on the Apple TV's Discover: the Apple TV app's hero details over
    /// the billboard (kind line and rating, cycle-driven dots).
    var tv: TV? = nil
    /// Library's hero: the button its own policy chose, which knows the title
    /// plays from a file on disk. Nil lets the catalog policy below decide.
    var libraryButton: AppleTitlePagePolicy.HeroButton? = nil
    @ViewBuilder var actions: (AppleTitlePagePolicy.HeroButton, @escaping () -> Void) -> Actions
    @State private var episodes: [AppleStremioEpisode] = []
    /// True once the episode lookup has answered; false when there was
    /// none to make (not a series, or no id to look up); nil while out.
    @State private var episodeLookupAnswered: Bool?
    /// Every lookup that can find a trailer has answered.
    @State private var actionMetadataLoaded = false
    /// The hero has waited long enough for them (`heroTrailerLookupPatience`).
    @State private var trailerLookupPatienceElapsed = false
    /// A trailer's video — pressed or autoplaying — is on screen. A press
    /// over a pressed one does nothing; over the muted autoplay preview it
    /// restarts the trailer with sound (`heroPressRequestsTrailer`). A press
    /// while one is still loading behind the art starts the load again, so a
    /// stalled trailer never leaves a dead button.
    @State private var trailerIsOnScreen = false
    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    @State private var previewTrailerKeys: [String] = []
    @State private var detailTrailerKeys: [String] = []
    @State private var trailerRequest: UUID?
    @State private var downloadCoordinator = AppleOfflineDownloadCoordinator()

    private var selectedEpisode: AppleStremioEpisode? {
        let store = ApplePlaybackStore()
        let progress = ApplePlaybackProgressFeed.shared.progress(for: progressID, in: store)
        let completedIDs = store.completedMediaIDs(among: episodes.map(\.id))
        return AppleTitlePagePolicy.heroEpisode(
            item: item, progress: progress, episodes: episodes, completedIDs: completedIDs,
            localResumeEpisode: AppleLocalLibraryStore.shared.resumeEpisode(for: item, group: nil, episodes: episodes)
        )
    }

    private var hasPlaybackRoute: Bool {
        AppleTitlePagePolicy.heroHasPlaybackRoute(
            item: item, sources: sources,
            hasLocalGroup: !AppleLocalLibraryStore.shared.matchingGroups(item).isEmpty,
            hasCompletedDownload: downloadCoordinator.state.isCompleted,
            episodeLookup: episodeLookup
        )
    }

    /// The title page's answer is not known yet: hold the button back.
    private var playbackRouteIsSettled: Bool {
        AppleTitlePagePolicy.heroRouteIsSettled(
            item: item, sources: sources,
            hasLocalGroup: !AppleLocalLibraryStore.shared.matchingGroups(item).isEmpty,
            hasCompletedDownload: downloadCoordinator.state.isCompleted,
            episodeLookup: episodeLookup
        )
    }

    /// What the hero's own episode lookup said, the title page's
    /// "Episodes aren't available" included (`heroHasPlaybackRoute`).
    private var episodeLookup: AppleTitlePagePolicy.HeroEpisodeLookup {
        if let episodeLookupAnswered { return episodeLookupAnswered ? (episodes.isEmpty ? .empty : .found) : .unknown }
        return trailerLookupPatienceElapsed ? .unknown : .pending
    }

    /// The Apple TV hero never offers a trailer (N23 removes them there).
    private var trailerAvailability: AppleTitlePagePolicy.TrailerAvailability {
        #if os(tvOS)
        .none
        #else
        // The iPhone's portrait hero is static: its trailer plays on the
        // title page, so the hero's button never says Play Trailer.
        phone != nil && !AppleHeroPortraitArt.phoneHeroPlaysTrailers ? .none
        : AppleTitlePagePolicy.trailerAvailability(hasTrailer: trailerKey != nil, lookupsAnswered: actionMetadataLoaded,
                                                 patienceElapsed: trailerLookupPatienceElapsed)
        #endif
    }

    private var primaryAction: AppleTitlePagePolicy.PrimaryAction? {
        if let libraryButton { return libraryButton.action }
        guard playbackRouteIsSettled else { return nil }
        return AppleTitlePagePolicy.heroPrimaryAction(
            type: item.type, progress: ApplePlaybackProgressFeed.shared.progress(for: progressID),
            selectedEpisode: selectedEpisode, isPlayable: hasPlaybackRoute, trailer: trailerAvailability
        )
    }

    private var actionButtons: Actions {
        actions(libraryButton ?? AppleTitlePagePolicy.HeroButton(action: primaryAction,
                                                                 isDownloaded: downloadCoordinator.state.isCompleted),
                performPrimaryAction)
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .playTrailer:
            // Art-first: the art stays and the button keeps its label; the
            // video fades in over it once it plays, or never, silently.
            guard AppleTrailerArtFirstPolicy.heroPressRequestsTrailer(
                videoIsOnScreen: trailerIsOnScreen, pressedTrailerPlaying: trailerRequest != nil) else {
                appleTrace("hero play trailer pressed: the pressed trailer is already playing (\(item.name))")
                return
            }
            appleTrace("hero play trailer pressed (\(trailerIsOnScreen ? "over the muted preview" : "from the art")) \(item.name)")
            trailerRequest = UUID()
        case .details:
            onOpenDetails()
        case .play, .playEpisode, .resume:
            onPlay()
        case nil:
            break
        }
    }

    private var trailerKey: String? {
        (detailTrailerKeys + previewTrailerKeys).first { AppleTrailerPreviewPolicy.embedURL(for: $0) != nil }
    }

    /// Use the title page's metadata clients and canonical-id resolution too:
    /// a catalog's private id may need resolving before it can list episodes.
    private func loadActionMetadata() async {
        episodes = []
        episodeLookupAnswered = item.type == "series" ? nil : false
        actionMetadataLoaded = false
        previewTrailerKeys = []
        detailTrailerKeys = []
        trailerRequest = nil
        trailerIsOnScreen = false
        let client = AppleStremioMetadataClient()
        let resolver = AppleMetadataResolver()
        let sources = sources
        let preferred = preferredSourceID
        let item = item
        let configuration = metadataConfiguration
        func addLookups(to group: inout TaskGroup<AppleHeroMetadataOutcome>, mediaID: String) {
            if item.type == "series" {
                group.addTask {
                    .episodes((try? await client.episodes(sources: sources, preferredSourceID: preferred,
                                                          mediaID: mediaID)) ?? [])
                }
            }
            // The details and preview lookups only feed the trailer key, so
            // the Apple TV, which plays no trailer, skips them.
            guard AppleTitlePagePolicy.offersTrailers() else { return }
            group.addTask {
                .details(try? await resolver.resolve(sources: sources, preferredSourceID: preferred,
                    type: item.type, mediaID: mediaID, configuration: configuration))
            }
        }
        await withTaskGroup(of: AppleHeroMetadataOutcome.self) { group in
            if AppleTitlePagePolicy.offersTrailers() {
                group.addTask {
                    .preview(await client.previewAssets(sources: sources, preferredSourceID: preferred,
                                                         type: item.type, mediaID: item.mediaID))
                }
            }
            if let canonicalID = ApplePlayGatingPolicy.canonicalMediaID(item.mediaID) {
                addLookups(to: &group, mediaID: canonicalID)
            } else if AppleMediaServerItemReference.parse(item.mediaID) == nil {
                group.addTask {
                    .identity(await client.imdbIdentifier(sources: sources, preferredSourceID: preferred,
                                                          type: item.type, id: item.mediaID))
                }
            }
            while let outcome = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                switch outcome {
                case .preview(let assets): previewTrailerKeys = assets?.trailerYouTubeKeys ?? []
                case .details(let details): detailTrailerKeys = details?.trailerYouTubeKeys ?? []
                case .identity(let id): addLookups(to: &group, mediaID: id ?? item.mediaID)
                case .episodes(let loaded):
                    episodes = loaded
                    episodeLookupAnswered = true
                    if loaded.isEmpty { appleTrace("hero episodes: none for \(item.name) — no Play") }
                }
            }
        }
        guard !Task.isCancelled else { return }
        // No episode lookup was made (a media-server title, or an id that
        // never resolved): no evidence either way.
        if episodeLookupAnswered == nil { episodeLookupAnswered = false }
        actionMetadataLoaded = true
    }

    /// The decoded still, handed to the iPhone hero's trailer so its cover
    /// paints these pixels the moment it is inserted — the title page does the
    /// same. Without it the cover loaded its own copy and the hero went black
    /// for a moment when the trailer started (iPhone sim, 2026-09-22).
    @State private var stillImage: CGImage?
    /// Whose still has loaded or failed; the trailer waits on it.
    @State private var stillOutcome: (itemID: String, art: AppleTrailerArtFirstPolicy.Art)?
    /// The still that has decoded, with its URL, for the luminance reading
    /// that picks each hero's scrim (`AppleHeroScrim`).
    @State private var loadedStill: AppleHeroLoadedStill?
    @State private var artMeasurement: AppleHeroArtMeasurement?

    /// The iPhone portrait hero's settled art (`AppleHomePhonePortraitStage`).
    @State private var portraitDecision: AppleHeroPortraitDecision?

    private var stillURL: URL? {
        if phone != nil { return portraitDecision?.art.imageURL }
        return item.backgroundURL ?? item.posterURL
    }

    /// The measured still for this page's art, or nil until it has been.
    private var artLuminance: AppleHeroLuminanceMap? {
        AppleHeroArtMeasurement.map(artMeasurement, for: stillURL)
    }

    private var stillArt: AppleTrailerArtFirstPolicy.Art {
        stillOutcome?.itemID == item.id ? stillOutcome?.art ?? .loading : .loading
    }

    private func recordStill(_ art: AppleTrailerArtFirstPolicy.Art) {
        let current = stillOutcome?.itemID == item.id ? stillArt : .loading
        stillOutcome = (item.id, current.settling(with: art))
    }

    struct Phone {
        let artHeight: CGFloat
        let copyFadeLine: CGFloat
    }

    struct Mac {
        let layout: AppleMacHeroLayout
    }

    struct TV {
        let cycle: AppleHeroRotation.Cycle
    }

    var body: some View {
        heroBody
            .appleMeasuresHeroArt(loadedStill) { artMeasurement = $0 }
            .task(id: "\(item.id):\(catalogConfigurationIdentity(sources))") { await loadActionMetadata() }
            .task(id: item.id) {
                trailerLookupPatienceElapsed = false
                try? await Task.sleep(for: AppleTitlePagePolicy.heroTrailerLookupPatience)
                guard !Task.isCancelled else { return }
                trailerLookupPatienceElapsed = true
            }
            // A pressed trailer holds the hero's page while it loads behind
            // the art; one that never plays lets go after 30 s, silently, and
            // the art simply stays (art-first, owner 2026-09-24).
            .task(id: trailerRequest) {
                guard trailerRequest != nil else { return }
                try? await Task.sleep(for: .seconds(AppleTrailerArtFirstPolicy.pressedTrailerGiveUp))
                guard !Task.isCancelled, !trailerIsOnScreen else { return }
                trailerRequest = nil
            }
            // A press belongs to the visit: leaving for another tab and
            // coming back must not start the trailer again by itself.
            .onDisappear { trailerRequest = nil }
            #if DEBUG
            // `-OpenStreamDebugPlayTrailer YES` presses Play Trailer once the
            // hero's lookups have found one, as on the title page, so a
            // headless shot can show the art and then the trailer.
            .task(id: "\(item.id):\(primaryAction == .playTrailer)") {
                guard UserDefaults.standard.bool(forKey: "OpenStreamDebugPlayTrailer"),
                      primaryAction == .playTrailer else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, primaryAction == .playTrailer, trailerRequest == nil else { return }
                performPrimaryAction()
            }
            #endif
            .task(id: "\(progressID):\(selectedEpisode?.id ?? "")") {
                let offlineID = selectedEpisode.map { "\(progressID):\($0.id)" } ?? progressID
                await downloadCoordinator.loadExisting(mediaID: offlineID, itemTitle: item.name)
            }
    }

    @ViewBuilder private var heroBody: some View {
        #if os(macOS) || os(iOS)
        if let mac {
            AppleHomeMacHero(item: item, layout: mac.layout, wordmark: wordmark,
                             wordmarkLookupPending: wordmarkLookupPending, stage: stage,
                             artLuminance: artLuminance, onOpenDetails: onOpenDetails) { actionButtons }
        } else {
            standardBody
        }
        #else
        standardBody
        #endif
    }

    @ViewBuilder
    private var standardBody: some View {
        #if os(tvOS)
        if let tv {
            AppleTVBillboard(item: item, wordmark: wordmark, wordmarkLookupPending: wordmarkLookupPending,
                             rotationCount: rotationCount,
                             rotationIndex: rotationIndex, stage: stage, artLuminance: artLuminance,
                             usesKindMetadata: true, cycle: tv.cycle) { actionButtons }
        } else {
            featuredBody
        }
        #else
        featuredBody
        #endif
    }

    @ViewBuilder
    private var featuredBody: some View {
        if let phone {
            AppleHomePhoneHero(item: item,
                               artHeight: AppleHomePhoneHeroLayout.portraitArtHeight(width: viewportSize.width,
                                                                                     limit: phone.artHeight),
                               copyFadeLine: phone.copyFadeLine,
                               wordmark: wordmark ?? portraitDecision?.logo, wordmarkLookupPending: wordmarkLookupPending,
                               showsTitle: portraitDecision.map(\.art.showsTitle),
                               stage: stage, artLuminance: artLuminance,
                               onOpenDetails: onOpenDetails) { actionButtons }
        } else {
            AppleFeaturedHero(
                item: item,
                viewportSize: viewportSize,
                wordmark: wordmark,
                wordmarkLookupPending: wordmarkLookupPending,
                rotationCount: rotationCount,
                rotationIndex: rotationIndex,
                stage: stage,
                artLuminance: artLuminance
            ) { actionButtons }
        }
    }

    private var stage: AnyView {
        if phone != nil, !AppleHeroPortraitArt.phoneHeroPlaysTrailers {
            return AnyView(
                AppleHomePhonePortraitStage(item: item) { decision, image in
                    portraitDecision = decision
                    stillImage = image
                    if let image, let url = decision.art.imageURL {
                        loadedStill = AppleHeroLoadedStill(url: url, image: image)
                        recordStill(.loaded)
                    } else {
                        recordStill(.failed)
                    }
                }
            )
        }
        return AnyView(
            ZStack {
                // The still sits outside the per-title identity below. It
                // was inside it, so every page change remounted it empty
                // and the hero showed a bare surface under the new copy
                // until the backdrop decoded (sim finding c, 2026-09-22).
                // It keeps the old still until the new one lands: across a
                // page change `AppleHeroPageGate` has already warmed it (the
                // iPhone portrait pages are separate views), and a resize
                // must never paint the loading surface over the hero.
                AppleRemoteImage(
                    url: stillURL,
                    placeholderSystemImage: "",
                    onLoad: { [stillURL] image in
                        stillImage = image
                        if let stillURL { loadedStill = AppleHeroLoadedStill(url: stillURL, image: image) }
                        recordStill(.loaded)
                        appleTrace("hero still loaded \(item.name) \(image.width)px")
                        AppleLaunchReadiness.shared.markFirstScreenReady()
                    },
                    onFailure: {
                        stillImage = nil
                        recordStill(.failed)
                        appleTrace("hero still failed \(item.name)")
                        AppleLaunchReadiness.shared.markFirstScreenReady()
                    },
                    loadingFill: AppleDesignTokens.surface,
                    keepsImageWhileReloading: true,
                    // The Mac window resizes live; decode the still once.
                    fixedPixelDimension: mac != nil ? AppleMacHeroLayout.stillPixelDimension : nil,
                    // Centred like the trailer's cover over it (N44).
                    fillAlignment: mac?.layout.platform == .mac ? .center : nil
                )
                #if !os(tvOS)
                AppleHomeHeroPreview(item: item, sources: sources, settings: settings,
                                     trailerRequest: trailerRequest, requestedTrailerKey: trailerKey,
                                     art: stillArt,
                                     artworkImage: phone != nil || mac != nil ? stillImage : nil,
                                     muteTopInset: mac.map { $0.layout.topInset + AppleMacHeroLayout.muteTopInset },
                                     // Under the top bar: the bottom of the art is under the copy.
                                     controlTopInset: phone.map { $0.copyFadeLine + 8 },
                                     onTrailerOnScreen: { trailerIsOnScreen = $0 })
                    .id(item.id)
                #endif
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                appleTrace("hero stage \(item.name) \(Int(size.width))x\(Int(size.height))")
            }
        )
    }
}

/// Promotional posters carry their own title treatment and badges in the art.
struct ApplePortraitPromoCard: View {
    let item: AppleCatalogItem
    let viewportWidth: CGFloat

    var body: some View {
        AppleCatalogCard(item: item, sizing: .portraitPromo, viewportWidth: viewportWidth)
    }
}

/// The rotation dots under the hero's buttons. `AppleFeaturedHero` draws it on
/// iPhone, iPad, Mac and Vision Pro; tvOS has its own focus-aware indicator.
struct AppleHomeHeroPageIndicator: View {
    let count: Int
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(.primary.opacity(0.2))
                    .frame(width: position == index ? 28 : 8, height: 4)
                    .overlay(alignment: .leading) {
                        if position == index {
                            Capsule().fill(.primary).frame(width: 28 * fill)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured \(index + 1) of \(count)")
        .task(id: "\(index):\(reduceMotion)") {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let progress = AppleHeroRotation.progress(at: .now)
            withTransaction(transaction) { fill = reduceMotion ? 1 : progress }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: AppleHeroRotation.interval * (1 - progress))) { fill = 1 }
        }
    }
}

#if !os(tvOS)
@MainActor
private struct AppleHomeHeroPreview: View {
    let item: AppleCatalogItem
    let sources: [AppleSource]
    let settings: AppleSettingsStore
    var trailerRequest: UUID? = nil
    var requestedTrailerKey: String? = nil
    /// The still under it: the trailer is not asked for until it is up.
    var art: AppleTrailerArtFirstPolicy.Art = .loading
    var artworkImage: CGImage? = nil
    /// The Mac hero's round mute button sits this far from the top of the
    /// art (below the toolbar); nil on every other hero.
    var muteTopInset: CGFloat? = nil
    /// The iPhone/iPad sound/play control's distance from the art's top.
    var controlTopInset: CGFloat? = nil
    /// The video came on screen over the art (true) or left it (false).
    var onTrailerOnScreen: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isPresented = false
    @State private var embedURL: URL?
    /// Every key the metadata named, and the one playing: a refused video
    /// moves on to the next (`AppleTrailerKeyFallbackPolicy`).
    @State private var trailerKeys: [String] = []
    @State private var trailerKeyIndex = 0
    @State private var trailerQuality: String?
    @State private var isPlaying = false
    /// The video is on screen, past the art (`AppleTrailerArtFirstPolicy`).
    @State private var isRevealed = false
    /// The art frame the still fills, which the 16:9 web view overhangs.
    @State private var artFrameSize: CGSize?
    @State private var isMuted = true
    /// The viewer turned the sound on with the trailer's control: the
    /// muted-only rule is lifted and the next hero starts with sound.
    @State private var soundUnlocked = false
    @State private var replayGeneration = 0
    #if os(iOS) || os(visionOS)
    @State private var systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
    #endif
    #if os(macOS)
    /// False while a pushed page covers Discover, or the window is off screen
    /// or fully covered (`AppleMacWindowPresence`).
    @State private var isInWindow = false
    @Environment(\.displayScale) private var displayScale
    #endif

    private var shouldPreview: Bool {
        #if os(macOS)
        let active = isVisible && isPresented && isInWindow && scenePhase == .active
            && AppleTrailerArtFirstPolicy.mayRequestTrailer(art: art, pressed: trailerRequest != nil)
        #else
        let active = isVisible && isPresented && scenePhase == .active
            && AppleTrailerArtFirstPolicy.mayRequestTrailer(art: art, pressed: trailerRequest != nil)
        #endif
        if trailerRequest != nil { return active }
        let autoplay = active && settings.autoPlayTrailer && !reduceMotion
        #if os(iOS) || os(visionOS)
        return autoplay && systemVideoAutoplayEnabled
        #else
        return autoplay
        #endif
    }

    /// The iPhone and iPad hero holds its art until the trailer's crop is
    /// final (N46b). Vision Pro, measured on no device, keeps the title
    /// page's reveal.
    private var settlesTrailerPicture: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            // Holds the art frame so scroll visibility is measured even with
            // no trailer up; the still itself is drawn by `AppleHomeBillboard`.
            Color.clear
            #if os(macOS)
            AppleMacWindowPresence { isInWindow = $0 }
                .accessibilityHidden(true)
            #endif
            #if os(iOS) || os(visionOS)
            if shouldPreview, let embedURL {
                AppleYouTubeAutoPreview(
                    url: embedURL, artworkURL: item.backgroundURL ?? item.posterURL,
                    artworkImage: artworkImage,
                    isLandscape: true, isPlaying: $isPlaying, isMuted: $isMuted,
                    allowsSound: trailerRequest != nil || soundUnlocked,
                    replayGeneration: $replayGeneration, showsReplay: !isPlaying,
                    coverSize: artFrameSize,
                    onStateChange: handleState,
                    onTap: { isPlaying.toggle() },
                    onMute: toggleSound,
                    onReplay: { replayGeneration &+= 1; isPlaying = true },
                    controlTopInset: controlTopInset,
                    settlesPictureBeforeReveal: settlesTrailerPicture
                )
                // Cover the art frame instead of fitting inside it. The embed
                // letterboxes the video against its own black ground, so a
                // 2.57:1 hero frame put ~180 pt of black down each side of a
                // 16:9 trailer — the "black bars around the video" the owner
                // reported on the iPad (2026-09-20). Sizing the web view to
                // 16:9 *over* the frame and letting the hero's `clipped()`
                // crop it means the still and the preview fill identically.
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                // …and then report only the space it was offered. A covering
                // child otherwise widens the stage, the stage widens the hero,
                // and the hero's copy column is laid out against a width wider
                // than the screen — which put Details off the right edge of an
                // iPhone and stopped the synopsis wrapping (2026-09-20).
                // The zero minimums are what make it so: a flexible frame
                // with no minimum takes its child's size as the minimum, so
                // `maxWidth: .infinity` alone still reported 960 pt on a
                // 402 pt iPhone. The still behind it then reloaded at the new
                // size (the grey frame when the trailer started) and the
                // preview fell under half visible, stopped, and restarted
                // every few seconds (traced on the iPhone sim, 2026-09-22).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                // A failed trailer leaves by crossfading back to the still.
                .transition(.opacity)
            }
            #elseif os(macOS)
            if shouldPreview, let embedURL {
                AppleMacYouTubeHeroPreview(url: embedURL, artworkImage: artworkImage,
                                           isPlaying: isPlaying, isMuted: isMuted, onStateChange: handleState)
                    // Report only the frame offered, never the web view's own
                    // size: a child that widens the stage widens the hero and
                    // reloads the still (the zero-minimum lesson, 2026-09-22).
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
                    .transition(.opacity)
                // Nothing is added over the art until the video is up.
                if isPlaying, isRevealed, let muteTopInset {
                    AppleMacHeroMuteButton(isMuted: isMuted) { isMuted.toggle() }
                        .padding(.top, muteTopInset)
                        .padding(.trailing, AppleMacHeroLayout.muteTrailingInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            #endif
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { artFrameSize = $0 }
        .onAppear {
            isPresented = true
            #if DEBUG && os(iOS)
            AppleHeroTrailerProbeIOS.applyDebugOrientation()
            #endif
        }
        .onDisappear { isPresented = false; stop() }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .preference(key: AppleHomeHeroTrailerStateKey.self,
                    value: .init(isPlaying: shouldPreview && isPlaying,
                                 isOnScreen: shouldPreview && isPlaying && isRevealed, isMuted: isMuted,
                                 isRequested: trailerRequest != nil))
        .onChange(of: settings.autoMuteTrailer) { _, muted in isMuted = muted }
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
            systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        }
        #endif
        // Low priority: the trailer is only ever an extra over the art, and
        // must not compete with the art and metadata still loading.
        .task(id: "\(item.id):\(shouldPreview):\(trailerRequest?.uuidString ?? ""):\(catalogConfigurationIdentity(sources))",
              priority: .low) {
            await startPreview()
        }
    }

    private func startPreview() async {
        stop()
        guard shouldPreview else { return }
        #if os(macOS)
        if trailerRequest == nil {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        let assets = await AppleStremioMetadataClient().previewAssets(sources: sources, type: item.type, mediaID: item.mediaID)
        let keys = AppleTrailerKeyFallbackPolicy.orderedKeys(
            preferred: trailerRequest != nil ? requestedTrailerKey : nil, keys: assets?.trailerYouTubeKeys ?? [])
        guard !Task.isCancelled, shouldPreview, trailerRequest == nil || requestedTrailerKey != nil, let key = keys.first else { return }
        // The best stream the hero can show pixel for pixel, never a default:
        // measured on the 16:9 player the video is drawn at (it overhangs
        // the hero and is cropped), in device pixels, at the size the page
        // lays the player out before scaling it back down.
        let frame = artFrameSize ?? CGSize(width: 0, height: AppleMacHeroLayout.minimumHeight)
        let pixelHeight = Double(AppleTrailerPreviewLayout.coverFrame(in: frame).height)
            * Double(displayScale)
            * Double(AppleMacYouTubeHeroPreview.layoutScale(displayScale: displayScale))
        let quality = AppleTrailerPreviewPolicy.quality(forPixelHeight: pixelHeight)
        guard let url = AppleTrailerPreviewPolicy.embedURL(for: key, quality: quality) else { return }
        trailerKeys = keys
        trailerKeyIndex = 0
        trailerQuality = quality
        // Always starts muted, as it does on the iPhone; the round button
        // top-right turns the sound on (the Mac has no audio session to lose).
        isMuted = trailerRequest == nil
        appleTrace("mac hero trailer start \(item.name) frame=\(Int(pixelHeight))px vq=\(quality)")
        embedURL = url
        isPlaying = true
        #else
        if trailerRequest == nil {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        let assets = await AppleStremioMetadataClient().previewAssets(sources: sources, type: item.type, mediaID: item.mediaID)
        let keys = AppleTrailerKeyFallbackPolicy.orderedKeys(
            preferred: trailerRequest != nil ? requestedTrailerKey : nil, keys: assets?.trailerYouTubeKeys ?? [])
        guard !Task.isCancelled, shouldPreview, trailerRequest == nil || requestedTrailerKey != nil, let key = keys.first,
              let url = AppleTrailerPreviewPolicy.embedURL(for: key) else { return }
        trailerKeys = keys
        trailerKeyIndex = 0
        trailerQuality = nil
        // Autoplay starts muted (owner 2026-10-09) unless the viewer has
        // already turned the sound on; the control over the video unmutes.
        isMuted = trailerRequest == nil && !soundUnlocked
        guard ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: trailerRequest != nil) else { return }
        if trailerRequest != nil { appleTrace("trailer unmuted (explicit press)") }
        appleTrace("hero trailer start \(item.name)")
        embedURL = url
        isPlaying = true
        #endif
    }

    #if os(iOS) || os(visionOS)
    private func toggleSound() {
        let next = AppleTrailerSoundBridge.tapped(isMuted: isMuted, allowsSound: trailerRequest != nil || soundUnlocked)
        if !next.isMuted, !ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: true) { return }
        // Sound on carries to the next hero this visit; muting again ends it.
        soundUnlocked = !next.isMuted
        isMuted = next.isMuted
        appleTrace("hero trailer sound \(next.isMuted ? "off" : "on") (sound control)")
    }
    #endif

    private func stop() {
        trailerKeys = []
        trailerKeyIndex = 0
        isPlaying = false
        if isRevealed { onTrailerOnScreen(false) }
        isRevealed = false
        embedURL = nil
    }

    private func handleState(_ state: String, muted: Bool, errorCode: Int?) {
        isMuted = muted
        if state == "error", playNextTrailerKey(errorCode: errorCode) { return }
        if let change = AppleTrailerArtFirstPolicy.videoLayerChange(forPlayerState: state) {
            isRevealed = change == .reveal
            onTrailerOnScreen(isRevealed)
        }
        if AppleTrailerArtFirstPolicy.leavesForTheArt(forPlayerState: state) {
            // Nothing to say: the art crossfades back over whatever the
            // player showed, and stays. A finished trailer leaves the same way.
            if state == "ended" { appleTrace("hero trailer ended: back to the art (\(item.name))") }
            withAnimation(.easeInOut(duration: AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: reduceMotion))) {
                stop()
            }
        }
        if state == "ended" || state == "paused" { isPlaying = false }
    }

    /// Loads the next key after YouTube refused this one (blocked embedding
    /// or gone), the art staying up meanwhile. False when there is none.
    private func playNextTrailerKey(errorCode: Int?) -> Bool {
        let code = errorCode.map(String.init) ?? "none"
        guard let next = AppleTrailerKeyFallbackPolicy.nextKeyIndex(
            after: trailerKeyIndex, errorCode: errorCode, keyCount: trailerKeys.count) else {
            appleTrace("hero trailer error=\(code) key \(trailerKeyIndex + 1)/\(trailerKeys.count): giving up (\(item.name))")
            return false
        }
        let url = trailerQuality.map { AppleTrailerPreviewPolicy.embedURL(for: trailerKeys[next], quality: $0) }
            ?? AppleTrailerPreviewPolicy.embedURL(for: trailerKeys[next])
        guard let url else { return false }
        appleTrace("hero trailer error=\(code) key \(trailerKeyIndex + 1)/\(trailerKeys.count): trying key \(next + 1) (\(item.name))")
        if isRevealed { onTrailerOnScreen(false) }
        isRevealed = false
        trailerKeyIndex = next
        embedURL = url
        isPlaying = true
        return true
    }
}
#endif
