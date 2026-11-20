import AVFoundation
import CoreGraphics
import Foundation
import MediaAccessibility
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the cue layer draws for one cue: a line of text or a decoded bitmap
/// (PGS/DVB) with its authored geometry and rich-text emphasis intact.
enum AppleSubtitleCueContent: Equatable {
    case text(String)
    case richText([AppleSubtitleTextRun])
    case image(AppleSubtitleBitmap)

    init(_ cue: AppleSubtitleCue) {
        switch cue.body {
        case .text(let s): self = .text(s)
        case .richText(let runs): self = .richText(runs)
        case .image(let bitmap): self = .image(bitmap)
        }
    }
}

/// Who draws subtitle cues, and which one is on screen.
enum AppleSubtitleCueLayerPolicy {
    /// True when the app has to draw cues over the stock AVKit player.
    ///
    /// On `.surface` the transport overlay carries its own cue layer. On
    /// `.avPlayer` the OpenStream engine keeps AVPlayer's legible group
    /// deselected on purpose (the WebVTT rendition exists for PiP and AirPlay
    /// only, Sodalite#38) and expects the host to draw; nothing did, so every
    /// MKV/TS subtitle and every live-TS caption played blank on a device
    /// (Q4a8 paths 1 and 2). Native embedded tracks remain AVKit's to draw;
    /// native sidecar tracks publish cues to this same layer.
    static func mountsOverStockPlayer(
        engine: ApplePlaybackEngineKind,
        route: ApplePlaybackPresentationRoute
    ) -> Bool {
        route == .avPlayer
    }

    /// Every cue overlapping `position`, in the engine's order. Pass the
    /// engine's `presentationTime`, not its scrub `position`. Plural because
    /// a PGS composition is one cue per object: a sign at the top and the line
    /// of dialogue at the bottom are on screen together, and `.first` used to
    /// drop one of them (Q4a8 §4). The engine empties its cue list when no
    /// track is selected, so "no track" reads as empty here too.
    ///
    /// Text cues that say the same thing are drawn once: roll-up captions
    /// repeat a line as it scrolls ("GOOD EVENING", "GOOD EVENING."), and three
    /// copies were stacked on screen (iPad v2 re-run). Of two lines where one
    /// is the start of the other, the longer one stays.
    ///
    /// `timing` is the viewer's per-play delay and frame-rate fix: the lookup
    /// runs at its cue clock, so a +2 s delay shows the 60 s cue at 62 s.
    static func activeCues(in cues: [AppleSubtitleCue], at position: Double,
                           timing: AppleSubtitleTiming = AppleSubtitleTiming()) -> [AppleSubtitleCue] {
        let position = timing.cueClock(at: position)
        let active = cues.filter { position >= $0.startTime && position < $0.endTime }
        guard active.count > 1 else { return active }
        let keys = active.map { cue in cue.text.map(dedupeKey) }
        return active.indices.compactMap { index in
            guard let key = keys[index], !key.isEmpty else { return active[index] }
            let covered = keys.indices.contains { other in
                guard other != index, let otherKey = keys[other] else { return false }
                if otherKey == key { return other > index } // keep the last copy
                return key.count >= 8 && otherKey.count > key.count && otherKey.hasPrefix(key)
            }
            return covered ? nil : active[index]
        }
    }

    /// A cue's words alone: case, spaces and punctuation do not make it new.
    private static func dedupeKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// The Mac's text cue size for a picture this tall. The 12 pt base is
    /// sidebar-sized; AVKit draws captions at about a twentieth of the
    /// picture's height, and on the default engine the app draws every
    /// caption on the Mac (N38), so its cues grow with the window the same way.
    static func macTextSize(base: CGFloat, pictureHeight: CGFloat) -> CGFloat {
        max(base, (pictureHeight * 0.045).rounded())
    }

    /// One row of the app's subtitle menu on the stock player.
    struct MenuEntry: Equatable, Identifiable {
        let trackID: Int?
        let title: String
        let isSelected: Bool
        var id: String { trackID.map(String.init) ?? "off" }
    }

    /// "Off" and then the same tracks the transport overlay's menu lists.
    static func menuEntries(
        tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        languagesAreExplicit: Bool,
        activeTrackID: Int?
    ) -> [MenuEntry] {
        // A stream whose subtitles are all in other languages still gets
        // "Off" alone, so the viewer can see there is nothing to pick.
        guard !tracks.isEmpty else { return [] }
        let choices = AppleSubtitleTrackFilter.menuChoices(
            tracks, preferredLanguages: preferredLanguages, activeTrackID: activeTrackID)
        return [MenuEntry(trackID: nil, title: "Off", isSelected: activeTrackID == nil)]
            + choices.map { choice in
                MenuEntry(trackID: choice.track.id, title: choice.title,
                          isSelected: activeTrackID.map(choice.memberIDs.contains) ?? false)
            }
    }

    /// The "More…" submenu under `menuEntries`: the stream's other
    /// languages (`AppleSubtitleTrackFilter.otherLanguageChoices`).
    static func moreMenuEntries(
        tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        activeTrackID: Int?
    ) -> [MenuEntry] {
        AppleSubtitleTrackFilter.otherLanguageChoices(
            tracks, preferredLanguages: preferredLanguages, activeTrackID: activeTrackID
        ).map { choice in
            MenuEntry(trackID: choice.track.id, title: choice.title,
                      isSelected: activeTrackID.map(choice.memberIDs.contains) ?? false)
        }
    }

    /// The submenu's title.
    static let moreMenuTitle = "More…"
}

#if canImport(UIKit) && !os(watchOS)
extension AppleSubtitleCueLayerPolicy {
    /// A UIKit captions menu's rows: `entries`, then "More…" holding `more`.
    static func uiMenuChildren(
        entries: [MenuEntry],
        more: [MenuEntry],
        select: @escaping @MainActor (Int?) -> Void
    ) -> [UIMenuElement] {
        func action(_ entry: MenuEntry) -> UIAction {
            let action = UIAction(title: entry.title, state: entry.isSelected ? .on : .off) { _ in select(entry.trackID) }
            action.accessibilityIdentifier = "player.subtitle.track.\(entry.id)"
            return action
        }
        var children: [UIMenuElement] = entries.map(action)
        if !more.isEmpty {
            let menu = UIMenu(title: moreMenuTitle, options: .singleSelection, children: more.map(action))
            menu.accessibilityIdentifier = "player.subtitle.more"
            children.append(menu)
        }
        return children
    }
}
#endif

/// Follows an engine's cues and tracks for the stock-player cue layer and the
/// app's subtitle menu. The transport overlay's model does the same job on
/// `.surface`; this is the part of it the stock player needs.
@MainActor
@Observable
final class AppleStockPlayerSubtitles {
    private(set) var cues: [AppleSubtitleCue] = []
    /// Inline UIKit players have no transport overlay, including on surface routes.
    private(set) var drawsInlineCues = false
    private(set) var menuEntries: [AppleSubtitleCueLayerPolicy.MenuEntry] = []
    /// The menu's "More…" rows: the stream's other languages.
    private(set) var moreEntries: [AppleSubtitleCueLayerPolicy.MenuEntry] = []
    /// Whether the current item has legible options, i.e. whether AVKit's
    /// own captions button is there (`AppleStockSubtitleMenuPolicy`).
    private(set) var stockPlayerListsCaptions = false
    /// The coordinator's per-play timing (`ApplePlaybackCoordinator.subtitleTiming`),
    /// handed in by the cue layer.
    private(set) var timing = AppleSubtitleTiming()
    private weak var probedItem: AVPlayerItem?
    private var legibleProbe: Task<Void, Never>?

    /// Runs for as long as the calling `.task` lives.
    func follow(_ engine: any ApplePlaybackEngine) async {
        refresh(from: engine)
        for await event in engine.events {
            switch event {
            case .position, .tracks, .route, .phase:
                refresh(from: engine)
            case .duration, .failure:
                break
            }
        }
    }

    /// The only selection path the stock player uses, so the menu tick and the
    /// cue on screen change together even while paused (no position ticks).
    func select(_ id: Int?, on engine: any ApplePlaybackEngine) {
        engine.selectSubtitleTrack(id: id)
        refresh(from: engine)
    }

    /// Takes the coordinator's timing and redraws now, so a nudge while
    /// paused moves the cue without waiting for a position tick.
    func setTiming(_ timing: AppleSubtitleTiming, on engine: any ApplePlaybackEngine) {
        guard timing != self.timing else { return }
        self.timing = timing
        refresh(from: engine)
    }

    func refresh(from engine: any ApplePlaybackEngine) {
        drawsInlineCues = engine.route == .surface || AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(
            engine: engine.kind, route: engine.route)
        // Nothing over AVKit's placeholder while PiP or AirPlay has the picture.
        let drawsHere = (engine as? AetherPlaybackEngine)?.captionHandoff.appDrawsCaptions ?? true
        let next = drawsHere
            ? AppleSubtitleCueLayerPolicy.activeCues(in: engine.subtitleCues, at: engine.presentationTime,
                                                   timing: timing) : []
        if next != cues { cues = next }
        // Same persisted list the overlay model reads, so both menus agree.
        let chosen = UserDefaults.standard.stringArray(forKey: AppleSubtitleLanguages.defaultsKey)
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: engine.subtitleTracks,
            preferredLanguages: chosen ?? [],
            languagesAreExplicit: chosen != nil,
            activeTrackID: engine.activeSubtitleTrackID)
        let more = entries.isEmpty ? [] : AppleSubtitleCueLayerPolicy.moreMenuEntries(
            tracks: engine.subtitleTracks,
            preferredLanguages: chosen ?? [],
            activeTrackID: engine.activeSubtitleTrackID)
        // More first: the observers of `menuEntries` rebuild with both.
        if more != moreEntries { moreEntries = more }
        if entries != menuEntries { menuEntries = entries }
        probeStockCaptions(of: engine.avPlayer?.currentItem)
    }

    private func probeStockCaptions(of item: AVPlayerItem?) {
        guard item !== probedItem else { return }
        probedItem = item
        legibleProbe?.cancel()
        if stockPlayerListsCaptions { stockPlayerListsCaptions = false }
        guard let item else { return }
        legibleProbe = Task { [weak self] in
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, self.probedItem === item else { return }
            let lists = !(group?.options.isEmpty ?? true)
            if lists != self.stockPlayerListsCaptions { self.stockPlayerListsCaptions = lists }
        }
    }

    isolated deinit { legibleProbe?.cancel() }
}

/// The active subtitle cues, sat against the **picture** rather than the
/// screen. Shared by the transport overlay (`.surface`) and the stock player
/// (`.avPlayer`). Draws nothing when `cues` is empty; never takes focus or
/// touches.
///
/// Text cues rest at the bottom, lifted by `textBottomLift` (the controls).
/// Bitmap cues (PGS/DVB) are placed where the disc authored them, on the full
/// screen the video fills, and do not move with the controls.
struct AppleSubtitleCueLayer: View {
    let cues: [AppleSubtitleCue]
    let videoSize: CGSize?
    var textBottomLift: CGFloat = 0
    /// Global y of the controls' and the Next Episode card's top edges while
    /// they are on screen. Text cues stay above both.
    var controlsTop: CGFloat? = nil
    var promptTop: CGFloat? = nil

    var body: some View {
        ZStack {
            AppleSubtitleTextCues(cues: cues.filter { $0.text != nil }, videoSize: videoSize,
                                  controlsTop: controlsTop, promptTop: promptTop)
                .padding(.bottom, textBottomLift)
            AppleSubtitleBitmapCues(cues: cues.filter { $0.text == nil }, videoSize: videoSize)
                // The video ignores the safe area, so its rect is the screen's.
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// Text cues as centred lines at the bottom of the picture.
private struct AppleSubtitleTextCues: View {
    @State private var appearance = AppleCaptionAppearance.system()
    #if os(tvOS)
    // Read from across a room: about the size the Apple TV app draws its
    // captions at on a 1080p screen (29 pt read as phone-sized, full test
    // 2026-10-01).
    @ScaledMetric(relativeTo: .subheadline) private var baseSize: CGFloat = 46
    #elseif os(macOS)
    @ScaledMetric(relativeTo: .subheadline) private var baseSize: CGFloat = 12
    #else
    @ScaledMetric(relativeTo: .subheadline) private var baseSize: CGFloat = 15
    #endif
    let cues: [AppleSubtitleCue]
    let videoSize: CGSize?
    var controlsTop: CGFloat? = nil
    var promptTop: CGFloat? = nil

    var body: some View {
        // On Apple TV the video is full-bleed so the inset adds nothing; on a
        // phone in portrait the video letterboxes into a band and the caption
        // used to float ~450 pt below it, in the black (2026-09-16). See
        // `AppleVideoFitting`.
        GeometryReader { proxy in
            VStack {
                Spacer()
                if !cues.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(cues) { cue in
                            Text(appearance.text(for: cue, baseSize: textSize(in: proxy.size)))
                                .multilineTextAlignment(.center)
                                #if DEBUG
                                .accessibilityIdentifier("player.caption.text")
                                #endif
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .shadow(color: .black, radius: 2)
                    // Inside the frame, not outside it. Padding applied
                    // *after* `.frame` expands the view instead of lifting
                    // the cue within it — which is why the first attempt
                    // built, passed its geometry tests and changed nothing
                    // on screen (2026-09-16).
                    .padding(.bottom, max(
                        AppleVideoFitting.captionBottomInset(container: proxy.size, videoSize: videoSize),
                        AppleSubtitleCueLift.clearance(
                            layerBottom: proxy.frame(in: .global).maxY,
                            controlsTop: controlsTop,
                            promptTop: promptTop)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.caption.text.viewport")
        #endif
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String))) { _ in
            appearance = .system()
        }
    }

    private func textSize(in container: CGSize) -> CGFloat {
        #if os(macOS)
        AppleSubtitleCueLayerPolicy.macTextSize(
            base: baseSize,
            pictureHeight: AppleVideoFitting.fittedRect(container: container, videoSize: videoSize).height)
        #else
        baseSize
        #endif
    }
}

/// Bitmap cues, each at its authored rect on the picture
/// (`AppleVideoFitting.bitmapSubtitleFrame`). No shadow: PGS carries its own
/// antialiased outline. Ordinary objects retain their authored scale; objects
/// larger than the viewport fit uniformly so no pixels are cropped.
private struct AppleSubtitleBitmapCues: View {
    let cues: [AppleSubtitleCue]
    let videoSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            ForEach(cues) { cue in
                if case .image(let bitmap) = cue.body {
                    let frame = AppleVideoFitting.bitmapSubtitleFrame(
                        rect: bitmap.rect,
                        canvasSize: bitmap.canvasSize,
                        container: proxy.size,
                        videoSize: videoSize
                    )
                    Image(decorative: bitmap.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        #if DEBUG
                        // UI tests measure the object, before position expands
                        // its layout wrapper to the whole viewport.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Subtitle")
                        .accessibilityIdentifier("player.caption.bitmap")
                        #endif
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.caption.viewport")
        #endif
    }
}

/// The cue layer mounted over the stock AVKit player. Its caller decides when
/// (`AppleSubtitleCueLayerPolicy.mountsOverStockPlayer`) and owns `subtitles`
/// so its own captions control can select through the same object.
struct AppleStockPlayerCueLayer: View {
    let engine: any ApplePlaybackEngine
    let subtitles: AppleStockPlayerSubtitles
    /// Extra lift for text cues, e.g. the live footer while it is up.
    var textBottomLift: CGFloat = 0
    /// The coordinator's per-play subtitle delay and frame-rate fix.
    var timing = AppleSubtitleTiming()

    var body: some View {
        // 24: the overlay's resting inset with its controls hidden. AVKit's
        // own bar is drawn by AVKit, which says nothing about its height.
        AppleSubtitleCueLayer(cues: subtitles.cues, videoSize: engine.videoSize,
                              textBottomLift: 24 + textBottomLift)
            .accessibilityIdentifier("player.stockCueLayer")
            .task(id: ObjectIdentifier(engine)) { await subtitles.follow(engine) }
            .onChange(of: timing, initial: true) { subtitles.setTiming(timing, on: engine) }
    }
}
