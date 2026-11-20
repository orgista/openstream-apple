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
/// The Apple TV and Vision Pro play the title's trailer from the user's own
/// server first (`AppleServerTrailerStore`); the Apple TV has no other, and
/// looks no YouTube trailer up (`AppleTitlePagePolicy.offersTrailers`).
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
    var mediaServerLibrary: AppleMediaServerLibraryStore? = nil
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
    @State private var actionMetadata: (pageID: String, details: AppleTMDBDetails?)?
    /// The hero has waited long enough for them (`heroTrailerLookupPatience`).
    @State private var trailerLookupPatienceElapsed = false
    /// A trailer's video — pressed or autoplaying — is on screen. A press
    /// over a pressed one does nothing; over the muted autoplay preview it
    /// restarts the trailer with sound (`heroPressRequestsTrailer`). A press
    /// while one is still loading behind the art starts the load again, so a
    /// stalled trailer never leaves a dead button.
    @State private var trailerIsOnScreen = false
    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    /// The wordmark that passed `AppleTransparentPNGLogoValidator` (iPhone
    /// and Apple TV heroes), and the candidate list it was checked for.
    @State private var validatedLogo: URL?
    @State private var validatedLogoTaskID: String?
    @State private var trailerRequest: UUID?
    /// The title's trailer on the user's server, and whether that lookup
    /// has answered for this page (the Vision Pro waits for it before
    /// YouTube: the server's file comes first).
    @State private var serverTrailerAnswer: (key: String, trailer: AppleServerTrailer?)?
    @State private var downloadCoordinator = AppleOfflineDownloadCoordinator()
    @State private var buttonSelection: AppleTitlePagePolicy.HeroButtonSelection?

    private var actionMetadataLoaded: Bool { actionMetadata?.pageID == item.id }

    private var details: AppleTMDBDetails? { actionMetadataLoaded ? actionMetadata?.details : nil }

    private var presentedItem: AppleCatalogItem {
        guard let details else { return item }
        return item.merging(details: details).withHeroArtwork(
            backgroundURL: item.backgroundURL ?? details.backdropURL, logoURL: details.logoURL)
    }

    private var serverTrailerLookupID: String {
        "\(item.id)|\(details?.mediaID ?? item.mediaID)|\(AppleServerTrailerStore.shared.revision)"
    }

    private var serverTrailerLookedUp: Bool { serverTrailerAnswer?.key == serverTrailerLookupID }

    private var serverTrailer: AppleServerTrailer? { serverTrailerLookedUp ? serverTrailerAnswer?.trailer : nil }

    private var selectedEpisode: AppleMediaEpisode? {
        let store = ApplePlaybackStore()
        let progress = ApplePlaybackProgressFeed.shared.progress(for: progressID, in: store)
        return AppleTitlePagePolicy.heroEpisode(
            item: item, progress: progress, episodes: [],
            localResumeEpisode: AppleLocalLibraryStore.shared.resumeEpisode(for: item, group: nil, episodes: [])
        )
    }

    private var hasPlaybackRoute: Bool {
        AppleTitlePagePolicy.hasPlaybackRoute(
            item: item,
            hasLocalGroup: !AppleLocalLibraryStore.shared.matchingGroups(item).isEmpty,
            hasCompletedDownload: downloadCoordinator.state.isCompleted
        )
    }

    /// The Apple TV hero never offers a trailer button (N23 removes them
    /// there): its server trailer plays by itself, muted.
    private var trailerAvailability: AppleTitlePagePolicy.TrailerAvailability {
        #if os(tvOS)
        .none
        #else
        AppleTitlePagePolicy.trailerAvailability(hasTrailer: trailerKey != nil || serverTrailer != nil,
                                                 lookupsAnswered: actionMetadataLoaded,
                                                 patienceElapsed: trailerLookupPatienceElapsed)
        #endif
    }

    private var primaryAction: AppleTitlePagePolicy.PrimaryAction? {
        if let libraryButton { return libraryButton.action }
        return AppleTitlePagePolicy.heroPrimaryAction(
            type: item.type, progress: ApplePlaybackProgressFeed.shared.progress(for: progressID),
            selectedEpisode: selectedEpisode, isPlayable: hasPlaybackRoute, trailer: trailerAvailability,
            playabilityKnown: playabilityKnown
        )
    }

    private var playabilityKnown: Bool {
        !sources.contains { $0.isEnabled && ($0.kind == .library || $0.kind == .nas) }
            || AppleLocalLibraryStore.shared.hasLoaded
    }

    private var actionButtons: Actions {
        actions(selectedButton.button, performPrimaryAction)
    }

    private var selectedButton: AppleTitlePagePolicy.HeroButtonSelection {
        if let buttonSelection, buttonSelection.page == item.id { return buttonSelection }
        return AppleTitlePagePolicy.HeroButtonSelection(page: item.id, action: primaryAction,
            isDownloaded: downloadCoordinator.state.isCompleted, retaining: buttonSelection)
    }

    private func performPrimaryAction() {
        switch selectedButton.button.action {
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

    /// The title's own trailer, else the one Rill's feed listed for it.
    private var trailerKey: String? {
        ((details?.trailerYouTubeKeys ?? []) + [mediaServerLibrary?.feedTrailerKey(for: item.mediaID)].compactMap { $0 })
            .first { AppleTrailerPreviewPolicy.embedURL(for: $0) != nil }
    }

    /// The hero asks for the title page's enriched details (for its trailers
    /// and the iPhone's logo) with the same canonical id the page uses.
    private func loadActionMetadata() async {
        actionMetadata = nil
        trailerRequest = nil
        trailerIsOnScreen = false
        let resolved: AppleTMDBDetails?
        if let reference = AppleMediaServerItemReference.parse(item.mediaID), let mediaServerLibrary {
            resolved = try? await mediaServerLibrary.heroMetadata(for: reference,
                configuration: metadataConfiguration)
        } else {
            resolved = try? await AppleMetadataResolver().resolve(
                sources: sources, preferredSourceID: preferredSourceID, type: item.type,
                mediaID: item.imdbID ?? ApplePlayGatingPolicy.canonicalMediaID(item.mediaID) ?? item.mediaID,
                configuration: metadataConfiguration, fallbackName: phone != nil ? item.name : nil)
        }
        guard !Task.isCancelled else { return }
        actionMetadata = (item.id, resolved)
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
    /// The page whose still is drawn. It trails `item` until the new still
    /// has decoded, so the crossfade never starts from a bare surface.
    @State private var stillPage: AppleHeroStillPage?
    /// Stills that failed to load. The hero moves on to its next one and
    /// skips them on later visits, so a server that lists art it cannot
    /// serve never blanks it.
    @State private var failedStills: Set<URL> = []

    /// The iPhone portrait hero's settled art (`AppleHomePhonePortraitStage`).
    @State private var portraitArt: AppleHeroPortraitArt?
    /// What that art is drawn from, at the hero's size: the iPhone trailer
    /// renders its cover from it once it has a video to play.
    @State private var portraitCover: AppleHeroPortraitCover?

    private var stillURL: URL? {
        if phone != nil { return portraitArt?.imageURL }
        return stillRequest.url
    }

    private var stillRequest: AppleCatalogArtworkPolicy.DisplayRequest {
        nextStill(skipping: failedStills)
            ?? AppleCatalogArtworkPolicy.heroRequest(item: presentedItem, pixelWidth: AppleCatalogArtworkPolicy.heroPixelWidth)
    }

    private func nextStill(skipping failed: Set<URL>) -> AppleCatalogArtworkPolicy.DisplayRequest? {
        AppleCatalogArtworkPolicy.heroRequest(item: presentedItem, catalogBackdropURL: details?.catalogBackdropURL,
                                              pixelWidth: AppleCatalogArtworkPolicy.heroPixelWidth, skipping: failed)
    }

    /// Returns whether the hero still has another still to try.
    private func stillFailed(_ url: URL?) -> Bool {
        var failed = failedStills
        if let url { failed.insert(url) }
        failedStills = failed
        return nextStill(skipping: failed) != nil
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
            .onChange(of: item.id, initial: true) { _, _ in
                buttonSelection = selectedButton
                #if DEBUG
                let action = buttonSelection?.button.action
                appleTrace("hero action \(ApplePlaybackIdentity.digest(for: item.mediaID).prefix(12)) \(action.map { String(describing: $0) } ?? "pending")")
                #endif
            }
            .appleMeasuresHeroArt(loadedStill) { artMeasurement = $0 }
            .task(id: item.id) { await loadActionMetadata() }
            .task(id: serverTrailerLookupID) {
                guard AppleTrailerSourcePolicy.looksUpServer() else { return }
                let key = serverTrailerLookupID
                serverTrailerAnswer = nil
                // A removed stage reports nothing: its video is off screen.
                trailerIsOnScreen = false
                do {
                    let trailerItem = item.withMediaID(details?.mediaID ?? item.mediaID)
                    let trailer = try await AppleServerTrailerStore.shared.trailer(for: trailerItem)
                    guard !Task.isCancelled else { return }
                    serverTrailerAnswer = (key, trailer)
                } catch {
                    // The servers changed: the task runs again for the new revision.
                }
            }
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
            .task(id: "\(item.id):\(selectedButton.button.action == .playTrailer)") {
                guard UserDefaults.standard.bool(forKey: "OpenStreamDebugPlayTrailer"),
                      selectedButton.button.action == .playTrailer else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, selectedButton.button.action == .playTrailer, trailerRequest == nil else { return }
                performPrimaryAction()
            }
            #endif
            .task(id: "\(progressID):\(selectedEpisode?.id ?? "")") {
                let offlineID = selectedEpisode.map { "\(progressID):\($0.id)" } ?? progressID
                await downloadCoordinator.loadExisting(mediaID: offlineID, itemTitle: item.name)
            }
    }

    @ViewBuilder private var heroBody: some View {
        #if os(macOS) || os(iOS) || os(visionOS)
        if let mac {
            AppleHomeMacHero(item: presentedItem, layout: mac.layout, wordmark: details?.logoURL ?? wordmark,
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
            // The same validated mark as the iPhone: a logo on a plate or a
            // photo draws the name instead.
            AppleTVBillboard(item: presentedItem, wordmark: presentedLogo,
                             wordmarkLookupPending: wordmarkLookupPending.map { $0 || validatedLogoTaskID != logoTaskID },
                             rotationCount: rotationCount,
                             rotationIndex: rotationIndex, stage: stage, artLuminance: artLuminance,
                             usesKindMetadata: true, cycle: tv.cycle) { actionButtons }
                .task(id: logoTaskID) { await validateLogo() }
        } else {
            featuredBody
        }
        #else
        featuredBody
        #endif
    }

    private var logoCandidates: [URL] {
        [details?.logoURL, wordmark, item.logoURL, details?.catalogLogoURL].compactMap { $0 }
    }

    private var presentedLogo: URL? {
        guard let validatedLogo, logoCandidates.contains(validatedLogo) else { return nil }
        return validatedLogo
    }

    private var logoTaskID: String {
        "\(item.id)|\(actionMetadataLoaded)|" + logoCandidates.map(\.absoluteString).joined(separator: "|")
    }

    private func validateLogo() async {
        let candidates = logoCandidates
        let validated = await AppleTransparentPNGLogoValidator.firstValid(in: candidates)
        guard !Task.isCancelled else { return }
        appleTrace("hero wordmark \(validated != nil ? "valid" : "none") candidates=\(candidates.count)"
            + " metadata=\(actionMetadataLoaded) (\(item.name))")
        if validated != nil || actionMetadataLoaded { validatedLogo = validated }
        validatedLogoTaskID = logoTaskID
        if let validated, let source = sources.first(where: { $0.id == preferredSourceID }) {
            await AppleHeroArtworkUpgrade.shared.rememberServerWordmark(validated, for: item,
                source: source, namespace: ApplePlaybackStore().namespace)
        }
    }

    @ViewBuilder
    private var featuredBody: some View {
        if let phone {
            AppleHomePhoneHero(item: presentedItem, artHeight: phone.artHeight, copyFadeLine: phone.copyFadeLine,
                               wordmark: presentedLogo,
                               wordmarkLookupPending: AppleHeroTitlePolicy.phoneWordmarkLookupPending(
                                   metadataLoaded: actionMetadataLoaded, lookupPending: wordmarkLookupPending == true,
                                   validatedTaskID: validatedLogoTaskID, taskID: logoTaskID),
                               stage: stage,
                               onOpenDetails: onOpenDetails) { actionButtons }
                .task(id: logoTaskID) { await validateLogo() }
        } else {
            AppleFeaturedHero(
                item: presentedItem,
                viewportSize: viewportSize,
                wordmark: details?.logoURL ?? wordmark,
                wordmarkLookupPending: wordmarkLookupPending,
                rotationCount: rotationCount,
                rotationIndex: rotationIndex,
                stage: stage,
                artLuminance: artLuminance
            ) { actionButtons }
        }
    }

    /// The iPhone trailer waits for its cover as well as the still, so the
    /// view it goes into never shows anything but the art drawn under it.
    private var phoneStillArt: AppleTrailerArtFirstPolicy.Art {
        stillArt == .loaded && portraitCover == nil ? .loading : stillArt
    }

    private var stage: AnyView {
        #if os(iOS) || os(visionOS)
        if let phone {
            // The settled portrait art, the trailer over it (muted autoplay,
            // the Apple TV app's rules: `AppleHeroTrailerGate`), cropped to
            // the same frame and crossfading in from the same pixels.
            return AnyView(
                ZStack {
                    AppleHomePhonePortraitStage(item: presentedItem, details: details, topInset: phone.copyFadeLine, onReady: { art, image in
                        portraitArt = art
                        stillImage = image
                        if let image, let url = art.imageURL {
                            loadedStill = AppleHeroLoadedStill(url: url, image: image)
                            recordStill(.loaded)
                        } else {
                            recordStill(.failed)
                        }
                    }, onCover: { portraitCover = $0 })
                    switch AppleTrailerSourcePolicy.heroSource(server: serverTrailer, serverLookedUp: serverTrailerLookedUp) {
                    case .server(let trailer):
                        AppleHeroServerTrailer(trailer: trailer, settings: settings, art: phoneStillArt,
                            artSize: stillImage.map { CGSize(width: $0.width, height: $0.height) },
                            trailerRequest: trailerRequest, onScreen: { trailerIsOnScreen = $0 })
                            .id(item.id)
                    case .youTube:
                        AppleHomeHeroPreview(item: presentedItem, sources: sources, settings: settings,
                                         trailerRequest: trailerRequest, requestedTrailerKey: trailerKey,
                                         availableTrailerKeys: details?.trailerYouTubeKeys ?? [],
                                         art: phoneStillArt, portraitCover: portraitCover, drawsArtworkURL: false,
                                         // Below the round Search/Refresh row (ApplePhoneLandingChrome);
                                         // the bottom of the art is under the copy.
                                         controlTopInset: phone.copyFadeLine + AppleDesignTokens.minimumActionSize + 8,
                                         onTrailerOnScreen: { trailerIsOnScreen = $0 })
                            .id(item.id)
                    case nil:
                        EmptyView()
                    }
                }
            )
        }
        #endif
        return AnyView(
            ZStack {
                // The carousel gates title changes. Only this title's still
                // may stay while a resize or artwork upgrade decodes.
                let shownStill = AppleHeroStillPage.displayed(current: currentStill, retained: stillPage)
                AppleHeroPageFade(page: shownStill.id, layer: .art) {
                    AppleRemoteImage(
                        url: shownStill.url,
                        placeholderSystemImage: "",
                        onLoad: { image in
                            stillPage = shownStill
                            stillImage = image
                            if let url = shownStill.url { loadedStill = AppleHeroLoadedStill(url: url, image: image) }
                            recordStill(.loaded)
                            appleTrace("hero still loaded \(item.name) \(image.width)px")
                            AppleLaunchMarks.record(.heroArt)
                            AppleLaunchReadiness.shared.markFirstScreenReady()
                        },
                        onFailure: {
                            appleTrace("hero still failed \(item.name)")
                            guard !stillFailed(shownStill.url) else { return }
                            stillImage = nil
                            recordStill(.failed)
                            AppleLaunchReadiness.shared.markFirstScreenReady()
                        },
                        loadingFill: AppleDesignTokens.surface,
                        keepsImageWhileReloading: true,
                        fixedPixelDimension: stillPixelDimension,
                        // Centred like the trailer's cover over it (N44).
                        fillAlignment: mac?.layout.platform == .mac ? .center : nil,
                        priority: .foreground
                    )
                }
                if shownStill != currentStill {
                    let requestedStill = currentStill
                    AppleRemoteImage(
                        url: requestedStill.url,
                        placeholderSystemImage: "",
                        onLoad: { _ in stillPage = requestedStill },
                        // The still on screen is this title's; it stays.
                        onFailure: { _ = stillFailed(requestedStill.url) },
                        loadingFill: .clear,
                        fixedPixelDimension: stillPixelDimension,
                        priority: .foreground
                    )
                    .opacity(0)
                    .allowsHitTesting(false)
                }
                switch AppleTrailerSourcePolicy.heroSource(server: serverTrailer, serverLookedUp: serverTrailerLookedUp) {
                case .server(let trailer):
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    AppleHeroServerTrailer(trailer: trailer, settings: settings, art: stillArt,
                                           artSize: stillImage.map { CGSize(width: $0.width, height: $0.height) },
                                           trailerRequest: trailerRequest, onScreen: { trailerIsOnScreen = $0 })
                        .id(item.id)
                    #else
                    EmptyView()
                    #endif
                case .youTube:
                    #if !os(tvOS)
                    AppleHomeHeroPreview(item: presentedItem, sources: sources, settings: settings,
                                         trailerRequest: trailerRequest, requestedTrailerKey: trailerKey,
                                         availableTrailerKeys: details?.trailerYouTubeKeys ?? [],
                                         art: stillArt,
                                         artworkImage: mac != nil ? stillImage : nil,
                                         muteTopInset: mac.map { $0.layout.topInset + AppleMacHeroLayout.muteTopInset },
                                         onTrailerOnScreen: { trailerIsOnScreen = $0 })
                        .id(item.id)
                    #else
                    EmptyView()
                    #endif
                case nil:
                    EmptyView()
                }
            }
            .onAppear { if stillPage == nil { stillPage = currentStill } }
        )
    }

    private var currentStill: AppleHeroStillPage { AppleHeroStillPage(id: item.id, url: stillURL) }

    /// Share the CDN variant's decode budget with launch prefetch.
    private var stillPixelDimension: Int? {
        stillRequest.fixedPixelDimension
    }
}

/// A hero page's still: which page, and the art URL it draws.
struct AppleHeroStillPage: Equatable {
    let id: String
    let url: URL?

    static func displayed(current: Self, retained: Self?) -> Self {
        guard let retained, retained.id == current.id else { return current }
        return retained
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

/// The rotating hero's dots under its buttons (iPhone on its side, Vision
/// Pro, iPad at the accessibility sizes), driven by its cycle like every
/// other hero's: the fill stops while the cycle holds. Reduce Motion holds
/// the cycle, so the active dot is drawn full.
struct AppleHomeHeroPageIndicator: View {
    let cycle: AppleHeroRotation.Cycle
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let activeWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<cycle.count, id: \.self) { position in
                Capsule()
                    .fill(.primary.opacity(0.2))
                    .frame(width: position == cycle.index ? Self.activeWidth : 8, height: 4)
                    .overlay(alignment: .leading) {
                        if position == cycle.index, reduceMotion {
                            Capsule().fill(.primary)
                        } else if position == cycle.index {
                            TimelineView(.animation(minimumInterval: cycle.fillTickInterval(width: Self.activeWidth, displayScale: displayScale),
                                                    paused: cycle.isPaused)) { context in
                                Capsule().fill(.primary).frame(width: Self.activeWidth * cycle.progress(at: context.date))
                            }
                        }
                    }
            }
        }
        #if os(visionOS)
        .accessibilityHidden(true)
        .overlay(alignment: .leading) {
            Color.clear
                .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                .accessibilityElement()
                .accessibilityLabel("Featured \(cycle.index + 1) of \(cycle.count)")
                .accessibilityIdentifier("home.featured.pages")
                .allowsHitTesting(false)
        }
        #else
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured \(cycle.index + 1) of \(cycle.count)")
        .accessibilityIdentifier("home.featured.pages")
        #endif
    }
}

#if !os(tvOS)
@MainActor
private struct AppleHomeHeroPreview: View {
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleHeroSideBleed) private var sideBleed
    let item: AppleCatalogItem
    let sources: [AppleSource]
    let settings: AppleSettingsStore
    var trailerRequest: UUID? = nil
    var requestedTrailerKey: String? = nil
    var availableTrailerKeys: [String] = []
    /// The still under it: the trailer is not asked for until it is up.
    var art: AppleTrailerArtFirstPolicy.Art = .loading
    var artworkImage: CGImage? = nil
    /// The iPhone's art, from which the cover is rendered just before its
    /// trailer starts (`AppleHeroPortraitCover`); it then stands in for
    /// `artworkImage`.
    var portraitCover: AppleHeroPortraitCover? = nil
    /// False on the iPhone, whose cover is its rendered portrait art alone,
    /// cropped as that art is: the item's backdrop URL would cover it.
    var drawsArtworkURL = true
    /// The Mac hero's round mute button sits this far from the top of the
    /// art (below the toolbar); nil on every other hero.
    var muteTopInset: CGFloat? = nil
    /// The iPhone/iPad sound/play control's distance from the art's top.
    var controlTopInset: CGFloat? = nil
    /// The video came on screen over the art (true) or left it (false).
    var onTrailerOnScreen: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appleHeroIsCovered) private var isCovered
    @Environment(\.appleHeroesSettled) private var heroesSettled
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
    /// The viewer's remembered choice is sound on (`AppleTrailerSoundMemory`):
    /// the muted-only rule is lifted and autoplay starts with sound.
    @State private var soundUnlocked = AppleTrailerSoundMemory.soundOn() == true
    /// When this page appeared: the trailer's start delay runs from here.
    @State private var pageShownAt = Date.now
    /// The player has reported playing since the trailer was asked for.
    @State private var playerStarted = false
    /// New each time this trailer fails or misses its startup timeout
    /// (`AppleHomeHeroTrailerStateKey.lastFailure`).
    @State private var lastFailure: UUID?
    @State private var replayGeneration = 0
    /// New each time the trailer plays to its end (`AppleHomeHeroTrailerStateKey.lastEnd`).
    @State private var lastEnd: UUID?
    #if os(iOS) || os(visionOS)
    @State private var systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
    #endif
    #if os(macOS)
    /// False while a pushed page covers Discover, or the window is off screen
    /// or fully covered (`AppleMacWindowPresence`).
    @State private var isInWindow = false
    @Environment(\.displayScale) private var displayScale
    #endif

    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// `portraitCover` as it is now (a running task sees the value it began
    /// with), and the cover last rendered from it.
    @State private var liveCover: AppleHeroPortraitCover?
    @State private var renderedCover: RenderedCover?

    private struct RenderedCover {
        let source: AppleHeroPortraitCover
        let image: CGImage?
    }

    private var shouldPreview: Bool {
        #if os(iOS) || os(visionOS)
        let systemVideoAutoplay = systemVideoAutoplayEnabled
        #else
        let systemVideoAutoplay = true
        #endif
        #if os(macOS)
        let windowIsVisible = isInWindow
        #else
        let windowIsVisible = true
        #endif
        return AppleHeroTrailerGate.plays(.init(
            autoPlaySetting: settings.autoPlayTrailer, reduceMotion: reduceMotion, lowPower: lowPowerMode,
            systemVideoAutoplay: systemVideoAutoplay, sceneIsActive: scenePhase == .active, halfVisible: isVisible,
            isPresented: isPresented, isCovered: isCovered, windowIsVisible: windowIsVisible,
            art: art, heroesSettled: heroesSettled, pressed: trailerRequest != nil))
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
                    url: embedURL, artworkURL: drawsArtworkURL ? item.backgroundURL ?? item.posterURL : nil,
                    artworkImage: renderedCover?.image ?? artworkImage,
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
                    AppleMacHeroMuteButton(isMuted: isMuted) {
                        isMuted.toggle()
                        AppleTrailerSoundMemory.remember(soundOn: !isMuted)
                    }
                        .padding(.top, muteTopInset)
                        .padding(.trailing, AppleMacHeroLayout.muteTrailingInset + sideBleed.trailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            #endif
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { artFrameSize = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onAppear {
            isPresented = true
            pageShownAt = .now
            #if DEBUG && os(iOS)
            AppleHeroTrailerProbeIOS.applyDebugOrientation()
            #endif
        }
        .onDisappear { isPresented = false; stop() }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .preference(key: AppleHomeHeroTrailerStateKey.self,
                    value: .init(isPlaying: shouldPreview && isPlaying,
                                 isOnScreen: shouldPreview && isPlaying && isRevealed, isMuted: isMuted,
                                 isRequested: trailerRequest != nil, lastEnd: lastEnd, lastFailure: lastFailure))
        .onChange(of: settings.autoMuteTrailer) { _, muted in isMuted = muted }
        .onChange(of: item.id) { pageShownAt = .now }
        .onChange(of: portraitCover, initial: true) { _, cover in liveCover = cover }
        // The frame changed under a playing trailer: draw its cover again.
        .task(id: liveCover) {
            if embedURL != nil { await renderCover() }
        }
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
            systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        }
        #endif
        // Low priority: the trailer is only ever an extra over the art, and
        // must not compete with the art and metadata still loading.
        .task(id: "\(item.id):\(shouldPreview):\(trailerRequest?.uuidString ?? ""):\(availableTrailerKeys.joined(separator: ","))",
              priority: .low) {
            await startPreview()
        }
        // A trailer that plays by itself and has not started playing within
        // the timeout counts as failed: the still stays and the page gets a
        // fresh dwell. A pressed one has its own 30 s give-up.
        .task(id: "\(embedURL?.absoluteString ?? ""):\(playerStarted)") {
            guard embedURL != nil, !playerStarted, trailerRequest == nil else { return }
            do { try await Task.sleep(for: .seconds(AppleTrailerStartPolicy.homeStartupTimeout)) } catch { return }
            guard embedURL != nil, !playerStarted else { return }
            appleTrace("hero trailer startup timed out: back to the art (\(item.name))")
            lastFailure = UUID()
            withAnimation(.easeInOut(duration: AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: reduceMotion))) {
                stop()
            }
        }
    }

    /// Waits out what is left of the still's delay before an autoplaying
    /// trailer goes in; a pressed one goes in at once. False when cancelled.
    private func waitForStartDelay() async -> Bool {
        guard trailerRequest == nil else { return true }
        let remaining = AppleTrailerStartPolicy.remainingDelay(on: AppleTrailerStartPolicy.current(isLargeLayout: isLargeLayout),
                                                               pageShownAt: pageShownAt, now: .now)
        guard remaining > 0 else { return true }
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return false }
        return true
    }

    private func startPreview() async {
        stop()
        guard shouldPreview else { return }
        #if os(macOS)
        let keys = AppleTrailerKeyFallbackPolicy.orderedKeys(
            preferred: trailerRequest != nil ? requestedTrailerKey : nil, keys: availableTrailerKeys)
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
        guard let url = AppleTrailerPreviewPolicy.embedURL(for: key, quality: quality),
              await waitForStartDelay(), shouldPreview else { return }
        trailerKeys = keys
        trailerKeyIndex = 0
        trailerQuality = quality
        // Autoplay starts muted unless the viewer chose sound before; the
        // round button top-right toggles it (the Mac has no audio session to lose).
        isMuted = trailerRequest == nil && AppleTrailerSoundMemory.autoplayStartsMuted()
        appleTrace("mac hero trailer start \(item.name) frame=\(Int(pixelHeight))px vq=\(quality)")
        playerStarted = false
        embedURL = url
        isPlaying = true
        #else
        let keys = AppleTrailerKeyFallbackPolicy.orderedKeys(
            preferred: trailerRequest != nil ? requestedTrailerKey : nil, keys: availableTrailerKeys)
        guard !Task.isCancelled, shouldPreview, trailerRequest == nil || requestedTrailerKey != nil, let key = keys.first,
              let url = AppleTrailerPreviewPolicy.embedURL(for: key) else { return }
        // The cover is drawn only now, with a video to play (Fable review 2026-10-14).
        await renderCover()
        guard !Task.isCancelled, shouldPreview, await waitForStartDelay(), shouldPreview else { return }
        trailerKeys = keys
        trailerKeyIndex = 0
        trailerQuality = nil
        // Autoplay starts muted (owner 2026-10-09) unless the viewer's
        // remembered choice is sound on; the control over the video toggles it.
        soundUnlocked = AppleTrailerSoundMemory.soundOn() == true
        isMuted = trailerRequest == nil && !soundUnlocked
        ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: trailerRequest != nil)
        if trailerRequest != nil { appleTrace("trailer unmuted (explicit press)") }
        appleTrace("hero trailer start \(item.name)")
        playerStarted = false
        embedURL = url
        isPlaying = true
        #endif
    }

    /// Renders the iPhone cover from the art now shown, unless it already was.
    private func renderCover() async {
        while let source = liveCover, renderedCover?.source != source {
            let image = await source.render()
            guard !Task.isCancelled else { return }
            renderedCover = RenderedCover(source: source, image: image)
        }
    }

    #if os(iOS) || os(visionOS)
    private func toggleSound() {
        let next = AppleTrailerSoundBridge.tapped(isMuted: isMuted, allowsSound: trailerRequest != nil || soundUnlocked)
        if !next.isMuted { ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: true) }
        // Remembered for every trailer after this one, across launches.
        soundUnlocked = !next.isMuted
        AppleTrailerSoundMemory.remember(soundOn: !next.isMuted)
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
        if state == "playing" || state == "revealed" { playerStarted = true }
        if state == "error", playNextTrailerKey(errorCode: errorCode) { return }
        if let change = AppleTrailerArtFirstPolicy.videoLayerChange(forPlayerState: state) {
            isRevealed = change == .reveal
            onTrailerOnScreen(isRevealed)
        }
        if AppleTrailerArtFirstPolicy.leavesForTheArt(forPlayerState: state) {
            // Nothing to say: the art crossfades back over whatever the
            // player showed, and stays. A finished trailer leaves the same way.
            if state == "ended" {
                appleTrace("hero trailer ended: back to the art (\(item.name))")
                lastEnd = UUID()
            } else {
                lastFailure = UUID()
            }
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
        playerStarted = false
        embedURL = url
        isPlaying = true
        return true
    }
}
#endif
