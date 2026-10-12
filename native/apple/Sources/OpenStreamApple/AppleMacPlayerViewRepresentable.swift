/// Whether the app's captions menu is shown beside the stock player on the
/// Mac and iPhone — one captions control wherever AVKit's can do the job.
///
/// AVKit lists the item's legible renditions and nothing else. Add-on
/// subtitle files (sidecars, ids from 1 000 000) never become one, and
/// neither do bitmap tracks (PGS, DVB, VobSub) or CEA-708, which the engine
/// draws itself. The default engine's loopback streams declare no renditions
/// on these platforms (`AetherPlaybackEngine.declaresNativeSubtitleRenditions`),
/// so AVKit shows no CC button at all there and the app's menu is the only
/// one. A stream whose tracks are all native text renditions needs no second
/// menu: AVKit's drives them through `ApplePlayerSubtitleSelection`.
@MainActor
enum AppleStockSubtitleMenuPolicy {
    static func showsAppMenu(tracks: [ApplePlaybackTrack], stockPlayerListsCaptions: Bool) -> Bool {
        guard !tracks.isEmpty else { return false }
        guard stockPlayerListsCaptions else { return true }
        return tracks.contains { !hasNativeRendition($0) }
    }

    static func hasNativeRendition(_ track: ApplePlaybackTrack) -> Bool {
        guard track.id < NativePlaybackEngine.externalSubtitleTrackIDBase else { return false }
        let codec = track.codec?.lowercased() ?? ""
        if ["eia_708", "cea708", "cea_708"].contains(codec) { return false }
        return !ApplePlayerSubtitleSelection.isBitmap(track)
    }
}

#if os(macOS)
import AVKit
import SwiftUI

/// The Mac's `AVPlayerView`, as the full player and Live's inline player both
/// use it: the picture scaled by View ▸ Zoom to Fill, and the "…" button
/// carrying Quality and — where AVKit's CC menu cannot do the job
/// (`AppleStockSubtitleMenuPolicy`) — the app's Subtitles menu.
struct AppleMacPlayerViewRepresentable: NSViewRepresentable {
    let playerView: AVPlayerView
    var zoomToFill = false
    /// AVKit's own full-screen button moves the video into a window of its
    /// own, away from the app's captions and buttons. Off wherever the app
    /// has a full-window player to offer instead.
    var showsAVKitFullScreenButton = false
    /// The full player takes the keyboard from the page it covers, so a
    /// Return cannot press the page's Play button again underneath it.
    var takesKeyboardFocus = false
    var subtitleEntries: [AppleSubtitleCueLayerPolicy.MenuEntry] = []
    /// The "More…" submenu: the stream's other subtitle languages.
    var moreSubtitleEntries: [AppleSubtitleCueLayerPolicy.MenuEntry] = []
    var showsSubtitleMenu = false
    var onSelectSubtitle: (Int?) -> Void = { _ in }
    /// The per-play subtitle delay and frame-rate fix, offered while a track is on.
    var subtitleTiming = AppleSubtitleTiming()
    var onChangeSubtitleTiming: ((AppleSubtitleTiming.Change) -> Void)?
    var onOtherSources: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        if takesKeyboardFocus {
            Task { @MainActor [weak playerView] in
                guard let playerView, let window = playerView.window else { return }
                window.makeFirstResponder(playerView)
            }
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let gravity = AppleMacPlayerFramePolicy.videoGravity(zoomToFill: zoomToFill)
        if nsView.videoGravity != gravity { nsView.videoGravity = gravity }
        if nsView.showsFullScreenToggleButton != showsAVKitFullScreenButton {
            nsView.showsFullScreenToggleButton = showsAVKitFullScreenButton
        }
        context.coordinator.onSelectSubtitle = onSelectSubtitle
        context.coordinator.onChangeSubtitleTiming = onChangeSubtitleTiming
        context.coordinator.onOtherSources = onOtherSources
        // Rebuilt only when what it lists changes: replacing the menu while
        // it is open would close it under the pointer.
        let signature = MenuSignature(otherSources: onOtherSources != nil,
                                      subtitles: showsSubtitleMenu ? subtitleEntries : [],
                                      moreSubtitles: showsSubtitleMenu ? moreSubtitleEntries : [],
                                      timing: subtitleTiming)
        guard signature != context.coordinator.menuSignature else { return }
        context.coordinator.menuSignature = signature
        nsView.actionPopUpButtonMenu = actionMenu(coordinator: context.coordinator)
    }

    struct MenuSignature: Equatable {
        let otherSources: Bool
        let subtitles: [AppleSubtitleCueLayerPolicy.MenuEntry]
        var moreSubtitles: [AppleSubtitleCueLayerPolicy.MenuEntry] = []
        var timing = AppleSubtitleTiming()
    }

    private func actionMenu(coordinator: Coordinator) -> NSMenu? {
        let menu = NSMenu(title: "Options")
        if onOtherSources != nil {
            let item = NSMenuItem(title: "Quality…", action: #selector(Coordinator.showOtherSources(_:)),
                                  keyEquivalent: "")
            item.target = coordinator
            item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if showsSubtitleMenu, !subtitleEntries.isEmpty {
            let tracks = NSMenu(title: "Subtitles")
            func subtitleItem(_ entry: AppleSubtitleCueLayerPolicy.MenuEntry) -> NSMenuItem {
                let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.selectSubtitle(_:)),
                                      keyEquivalent: "")
                item.target = coordinator
                item.representedObject = entry.trackID
                item.state = entry.isSelected ? .on : .off
                return item
            }
            for entry in subtitleEntries { tracks.addItem(subtitleItem(entry)) }
            if !moreSubtitleEntries.isEmpty {
                let more = NSMenu(title: AppleSubtitleCueLayerPolicy.moreMenuTitle)
                for entry in moreSubtitleEntries { more.addItem(subtitleItem(entry)) }
                let moreItem = NSMenuItem(title: AppleSubtitleCueLayerPolicy.moreMenuTitle, action: nil, keyEquivalent: "")
                moreItem.submenu = more
                tracks.addItem(moreItem)
            }
            if onChangeSubtitleTiming != nil,
               AppleSubtitleTimingMenu.isOffered(subtitleSelected: subtitleEntries.contains {
                   $0.trackID != nil && $0.isSelected }) {
                tracks.addItem(.separator())
                for item in timingItems(coordinator: coordinator) { tracks.addItem(item) }
            }
            let item = NSMenuItem(title: "Subtitles", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
            item.submenu = tracks
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func timingItems(coordinator: Coordinator) -> [NSMenuItem] {
        func actionItem(_ title: String, _ change: AppleSubtitleTiming.Change, enabled: Bool = true,
                        on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: enabled ? #selector(Coordinator.changeTiming(_:)) : nil,
                                  keyEquivalent: "")
            item.target = coordinator
            item.representedObject = TimingChangeBox(change)
            item.state = on ? .on : .off
            return item
        }
        let delay = NSMenu(title: AppleSubtitleTimingMenu.title)
        for step in AppleSubtitleTimingMenu.steps { delay.addItem(actionItem(step.title, .nudge(step.seconds))) }
        delay.addItem(actionItem(AppleSubtitleTimingMenu.resetTitle, .resetDelay, enabled: subtitleTiming.delay != 0))
        let delayItem = NSMenuItem(title: AppleSubtitleTimingMenu.titleWithValue(subtitleTiming), action: nil,
                                   keyEquivalent: "")
        delayItem.submenu = delay
        let rate = NSMenu(title: AppleSubtitleTimingMenu.frameRateTitle)
        for fix in AppleSubtitleTiming.FrameRateFix.allCases {
            rate.addItem(actionItem(fix.title, .frameRate(fix), on: subtitleTiming.frameRateFix == fix))
        }
        let rateItem = NSMenuItem(title: AppleSubtitleTimingMenu.frameRateTitle, action: nil, keyEquivalent: "")
        rateItem.submenu = rate
        return [delayItem, rateItem]
    }

    final class TimingChangeBox: NSObject {
        let change: AppleSubtitleTiming.Change
        init(_ change: AppleSubtitleTiming.Change) { self.change = change }
    }

    @MainActor final class Coordinator: NSObject {
        var menuSignature: MenuSignature?
        var onSelectSubtitle: (Int?) -> Void = { _ in }
        var onChangeSubtitleTiming: ((AppleSubtitleTiming.Change) -> Void)?

        @objc func changeTiming(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? TimingChangeBox else { return }
            onChangeSubtitleTiming?(box.change)
        }
        var onOtherSources: (() -> Void)?

        @objc func selectSubtitle(_ sender: NSMenuItem) {
            onSelectSubtitle(sender.representedObject as? Int)
        }

        @objc func showOtherSources(_ sender: NSMenuItem) {
            onOtherSources?()
        }
    }
}
#endif
