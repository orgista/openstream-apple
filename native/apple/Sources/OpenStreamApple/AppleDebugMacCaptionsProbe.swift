#if DEBUG && os(macOS)
import AppKit
import AVFoundation
import AVKit
import CoreImage
import SwiftUI

/// Drives the Mac player's captions the way a viewer does and photographs
/// each step, DEBUG only (N38).
///
/// `-OpenStreamCaptionsProbe <dir>` with
/// `-OpenStreamCaptionsProbeSteps "stock:en,stock:off,app:fr,sidecar,app:off"`
/// runs once the player is on screen: `stock:` does what AVKit's CC menu does
/// (`select(_:in:)` on the item), `app:` what the app's own menu does
/// (through the host, as `AppleMacPlayerViewRepresentable` calls it),
/// `sidecar` adds `-OpenStreamCaptionsProbeSidecar <file.srt>` as a sidecar
/// track and picks it. After each step it writes `<n>-<step>.png` (the window,
/// as `AppleMacWindowShot` renders it) and a line with what each renderer
/// holds: the item's selected legible option, the engine's active track and
/// app-drawn cues, and the text AVPlayer itself is rendering for the item
/// (`AVPlayerItemLegibleOutput`, which leaves player rendering on).
///
/// `pip:on` / `pip:off` open and close a Picture in Picture window on the
/// engine's player and report it to the host the way the stock player's
/// PiP delegate does (N42). No TCC grant reaches another process's window,
/// so each PiP step also writes `<n>-pip-frame.png`: the item's current video
/// frame (`AVPlayerItemVideoOutput`) with the strings AVPlayer is rendering
/// for its selected legible option drawn over it — what the PiP window shows,
/// reconstructed from the player's own outputs.
@MainActor
enum AppleDebugMacCaptionsProbe {
    /// Opens `-OpenStreamVisionPlaybackURL <file or 127.0.0.1 URL>` in the window's player
    /// stage when the probe is requested. The Mac's Settings are a window of
    /// their own, so the Sources pane's fixture hook never runs in the main
    /// window.
    struct Presenter: ViewModifier {
        let settings: AppleSettingsStore
        @State private var presentation: AppleMediaPlayerPresentation?

        func body(content: Content) -> some View {
            content
                .modifier(AppleMacPlayerStagePresenter(presentation: $presentation))
                .task {
                    let defaults = UserDefaults.standard
                    guard defaults.string(forKey: "OpenStreamCaptionsProbe") != nil,
                          let raw = defaults.string(forKey: "OpenStreamVisionPlaybackURL"),
                          let url = URL(string: raw), url.isFileURL || url.host == "127.0.0.1" else { return }
                    try? await Task.sleep(for: .seconds(2))
                    presentation = AppleMediaPlayerPresentation(
                        request: ApplePlaybackRequest(url: url, mediaID: "captions-probe",
                                                      title: url.lastPathComponent, sourceKind: .files),
                        settings: settings)
                }
        }
    }

    static func runIfRequested(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator,
                               subtitles: AppleStockPlayerSubtitles) async {
        let defaults = UserDefaults.standard
        guard let dir = defaults.string(forKey: "OpenStreamCaptionsProbe"), dir.hasPrefix("/") else { return }
        let steps = (defaults.string(forKey: "OpenStreamCaptionsProbeSteps") ?? "stock:en,stock:off")
            .split(separator: ",").map(String.init)
        let output = URL(fileURLWithPath: dir)
        let engine = coordinator.engine
        var log = ["CAPTIONS-PROBE engine=\(engine.kind.rawValue)"]
        // Wait for a ready item, then hold the picture on a cue.
        for _ in 0..<150 {
            if engine.avPlayer?.currentItem?.status == .readyToPlay || engine.route == .surface { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1.5))
        engine.pause()
        await engine.seek(to: 1.5)
        let legible = LegibleTap()
        if let item = engine.avPlayer?.currentItem { legible.attach(to: item) }
        let pip = PictureInPictureDriver(host: host)
        let frames = FrameTap()
        log.append("CAPTIONS-PROBE route=\(engine.route) tracks=\(engine.subtitleTracks.map { "\($0.id):\($0.language ?? "-"):\($0.title)" })")
        log.append("CAPTIONS-PROBE menu=\(subtitles.menuEntries.map(\.title))")
        log.append("CAPTIONS-PROBE macAppMenu=\(AppleStockSubtitleMenuPolicy.showsAppMenu(tracks: engine.subtitleTracks, stockPlayerListsCaptions: subtitles.stockPlayerListsCaptions))")
        log.append(contentsOf: await state(engine: engine, legible: legible, label: "start"))
        shoot(to: output.appending(path: "0-start.png"), log: &log)
        for (index, step) in steps.enumerated() {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let action = parts.first ?? ""
            let argument = parts.count > 1 ? parts[1] : ""
            switch action {
            case "stock":
                stockSelect(language: argument == "off" ? nil : argument, engine: engine)
            case "app":
                let id = argument == "off" ? nil : trackID(language: argument, in: engine)
                host.selectSubtitleTrack(id: id)
                subtitles.refresh(from: engine)
                // In PiP the engine fills the new rendition before selecting
                // it; wait for AVKit's selection to reach the language.
                if pip.isActive, argument != "off" {
                    let started = Date()
                    for _ in 0..<80 {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let item = engine.avPlayer?.currentItem,
                              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                              let tag = item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag
                        else { continue }
                        if AppleSubtitleTrackFilter.normalized(tag) == AppleSubtitleTrackFilter.normalized(argument) { break }
                    }
                    log.append("CAPTIONS-PROBE pip reselect took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                }
            case "sidecar":
                if let path = defaults.string(forKey: "OpenStreamCaptionsProbeSidecar") {
                    engine.addExternalSubtitleTracks([AppleExternalSubtitleTrack(
                        id: "probe-sidecar", languageCode: argument.isEmpty ? "en" : argument,
                        displayName: "Probe", url: URL(fileURLWithPath: path))])
                    try? await Task.sleep(for: .milliseconds(300))
                    let id = engine.subtitleTracks.last { $0.id >= AetherPlaybackEngine.externalSubtitleTrackIDBase }?.id
                    host.selectSubtitleTrack(id: id)
                    subtitles.refresh(from: engine)
                }
            case "engine":
                engine.selectSubtitleTrack(id: argument == "off" ? nil : trackID(language: argument, in: engine))
                subtitles.refresh(from: engine)
            case "detach":
                let layer = (engine as? AetherPlaybackEngine)?.aetherEngine.nativePlayerLayer
                log.append("CAPTIONS-PROBE engine layer: player=\(layer?.player != nil) inTree=\(layer?.superlayer != nil)")
                layer?.player = nil
            case "criteria":
                engine.avPlayer?.appliesMediaSelectionCriteriaAutomatically = argument == "on"
            case "pip":
                if argument == "on" {
                    log.append(contentsOf: await pip.start(engine: engine))
                } else {
                    log.append(contentsOf: await pip.stop())
                }
                // The handoff rebuilds the item: wait for the rebuilt one and
                // (going away) for AVKit's selection on it.
                let wantsSelection = argument == "on" && engine.activeSubtitleTrackID != nil
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let aether = engine as? AetherPlaybackEngine,
                          aether.captionHandoff.stage == .native || aether.captionHandoff.stage == .app,
                          let item = engine.avPlayer?.currentItem, item.status == .readyToPlay else { continue }
                    guard wantsSelection else { break }
                    if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                       item.currentMediaSelection.selectedMediaOption(in: group) != nil { break }
                }
                try? await Task.sleep(for: .milliseconds(500))
            default:
                log.append("CAPTIONS-PROBE unknown step \(step)")
            }
            // Play a moment so the cue for the new selection reaches both
            // renderers (legible output only pushes as the playhead moves),
            // then hold the frame for the shot.
            if let item = engine.avPlayer?.currentItem {
                legible.attach(to: item)
                frames.attach(to: item)
            }
            pip.follow(engine.avPlayer)
            legible.reset()
            // A seek makes the legible output push the cue under the
            // playhead again; it only pushes on cue boundaries otherwise.
            await engine.seek(to: 1.5 + Double(index) * 0.2)
            engine.play()
            try? await Task.sleep(for: .seconds(1.2))
            // A rendition AVKit has just selected can take a few seconds to
            // deliver its first cue; keep playing (up to 6 s) until it does.
            if pip.isActive, engine.activeSubtitleTrackID != nil {
                for _ in 0..<24 where legible.recent.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            engine.pause()
            try? await Task.sleep(for: .milliseconds(700))
            subtitles.refresh(from: engine)
            try? await Task.sleep(for: .milliseconds(300))
            log.append(contentsOf: await state(engine: engine, legible: legible, label: step))
            log.append("CAPTIONS-PROBE menu=\(subtitles.menuEntries.map { ($0.isSelected ? "✓" : "") + $0.title })")
            let name = "\(index + 1)-\(step.replacingOccurrences(of: ":", with: "-")).png"
            shoot(to: output.appending(path: name), log: &log)
            if pip.isActive, let item = engine.avPlayer?.currentItem {
                frames.write(item: item, caption: legible.recent,
                             to: output.appending(path: "\(index + 1)-pip-frame.png"), log: &log)
            }
        }
        if pip.isActive { log.append(contentsOf: await pip.stop()) }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
           let player = playerView(in: window.contentView) as? AVPlayerView {
            let items = player.actionPopUpButtonMenu?.items.map { item in
                item.title + (item.submenu.map { " [" + $0.items.map { ($0.state == .on ? "✓" : "") + $0.title }
                    .joined(separator: ", ") + "]" } ?? "")
            } ?? []
            log.append("CAPTIONS-PROBE player ⋯ menu: \(items)")
        }
        log.append("CAPTIONS-PROBE done")
        FileHandle.standardError.write(Data((log.joined(separator: "\n") + "\n").utf8))
        try? (log.joined(separator: "\n") + "\n").write(to: output.appending(path: "probe.log"),
                                                        atomically: true, encoding: .utf8)
    }

    private static func trackID(language: String, in engine: any ApplePlaybackEngine) -> Int? {
        let wanted = AppleSubtitleTrackFilter.normalized(language)
        return engine.subtitleTracks.first { AppleSubtitleTrackFilter.normalized($0.language ?? "") == wanted }?.id
    }

    private static func stockSelect(language: String?, engine: any ApplePlaybackEngine) {
        guard let item = engine.avPlayer?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        let option = language.flatMap { wanted in
            group.options.first {
                AppleSubtitleTrackFilter.normalized($0.extendedLanguageTag ?? $0.locale?.identifier ?? "")
                    == AppleSubtitleTrackFilter.normalized(wanted)
                    && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }
        }
        item.select(option, in: group)
    }

    private static func state(engine: any ApplePlaybackEngine, legible: LegibleTap, label: String) async -> [String] {
        var selected = "no item"
        var options: [String] = []
        if let item = engine.avPlayer?.currentItem,
           let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            selected = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "none"
            options = group.options.map { "\($0.displayName)[\($0.extendedLanguageTag ?? "-")]" }
        }
        let cues = AppleSubtitleCueLayerPolicy.activeCues(in: engine.subtitleCues, at: engine.presentationTime)
        let handoff = (engine as? AetherPlaybackEngine)?.captionHandoff
        return ["CAPTIONS-PROBE [\(label)] handoff=\(handoff.map { "\($0.stage)" } ?? "-") "
                + "pictureAway=\(handoff?.pictureIsAway.description ?? "-") appDraws=\(handoff?.appDrawsCaptions.description ?? "-") "
                + "player=\(engine.avPlayer.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xffff, radix: 16) } ?? "-") "
                + "item=\(engine.avPlayer?.currentItem.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xffff, radix: 16) } ?? "-") "
                + "avkitOptions=\(options) avkitSelected=\(selected) "
                + "engineActive=\(engine.activeSubtitleTrackID.map(String.init) ?? "nil") "
                + "criteriaAuto=\(engine.avPlayer?.appliesMediaSelectionCriteriaAutomatically.description ?? "-") "
                + "appCues=\(cues.compactMap(\.text)) avplayerRenders=\(legible.recent)"]
    }

    /// AVKit draws captions in Core Animation layers inside the player
    /// view, which `cacheDisplay` leaves out with the video. Rendering the
    /// player view's layer tree directly keeps them; the layers carrying
    /// content are listed so an empty frame can be told from a missed one.
    private static func shootPlayerLayers(to url: URL, log: inout [String]) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let player = playerView(in: window.contentView), let layer = player.layer else {
            log.append("CAPTIONS-PROBE layers: no player view")
            return
        }
        var drawn: [String] = []
        func visit(_ layer: CALayer, depth: Int) {
            if layer.contents != nil || (layer as? CATextLayer)?.string != nil, !layer.isHidden, layer.opacity > 0,
               layer.bounds.width > 4, layer.bounds.height > 4 {
                drawn.append("\(type(of: layer))@\(Int(layer.frame.minY))h\(Int(layer.bounds.height))")
            }
            layer.sublayers?.forEach { visit($0, depth: depth + 1) }
        }
        visit(layer, depth: 0)
        log.append("CAPTIONS-PROBE layers with content: \(drawn.prefix(12))")
        let scale = window.backingScaleFactor
        let size = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        if let image = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                log.append("CAPTIONS-PROBE layers shot: \(url.lastPathComponent)")
            }
        }
    }

    private static func shootWindow(_ window: NSWindow, to url: URL, log: inout [String]) {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
            log.append("CAPTIONS-PROBE shot: \(url.lastPathComponent)")
        }
    }

    /// The accessibility labels under `view`, for reading a sheet's rows.
    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        var pending: [Any] = [view]
        while let next = pending.popLast(), found.count < 40 {
            if let element = next as? NSView {
                let label = element.accessibilityLabel() ?? (element as? NSTextField)?.stringValue ?? ""
                if !label.isEmpty, !found.contains(label) { found.append(label) }
                pending.append(contentsOf: (element.accessibilityChildren() ?? []).reversed())
                pending.append(contentsOf: element.subviews.reversed())
            } else if let element = next as? NSAccessibilityElement {
                let label = element.accessibilityLabel() ?? ""
                if !label.isEmpty, !found.contains(label) { found.append(label) }
                pending.append(contentsOf: (element.accessibilityChildren() ?? []).reversed())
            }
        }
        return found
    }

    private static func playerView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is AVPlayerView { return view }
        for subview in view.subviews { if let found = playerView(in: subview) { return found } }
        return nil
    }

    private static func shoot(to url: URL, log: inout [String]) {
        shootPlayerLayers(to: url.deletingPathExtension().appendingPathExtension("layers.png"), log: &log)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            log.append("CAPTIONS-PROBE shot: no window")
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
            log.append("CAPTIONS-PROBE shot: \(url.lastPathComponent)")
        }
    }

    /// The strings AVPlayer delivers for the selected legible option. Player
    /// rendering stays on (`suppressesPlayerRendering` is false), so this
    /// reads what AVKit draws without changing it.
    @MainActor
    private final class LegibleTap: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        private(set) var recent: [String] = []
        private var output = AVPlayerItemLegibleOutput()
        private weak var item: AVPlayerItem?

        func reset() { recent = [] }

        /// One output per item: the caption handoff swaps the item (N42).
        func attach(to item: AVPlayerItem) {
            guard item !== self.item else { return }
            if let previous = self.item { previous.remove(output) }
            self.item = item
            output = AVPlayerItemLegibleOutput()
            output.suppressesPlayerRendering = false
            output.setDelegate(self, queue: .main)
            item.add(output)
        }

        nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                       didOutputAttributedStrings strings: [NSAttributedString],
                                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
            let texts = strings.map(\.string)
            MainActor.assumeIsolated { self.recent = texts }
        }
    }

    /// A Picture in Picture window on the engine's player. `AVPlayerView`
    /// has no public way to start its own, so a second `AVPlayerLayer` on the
    /// same player, laid under the player view's, backs the controller; the
    /// host hears about it through the same entry its PiP delegate uses.
    @MainActor
    private final class PictureInPictureDriver: NSObject, AVPictureInPictureControllerDelegate {
        private let host: ApplePlayerHost
        private let layer = AVPlayerLayer()
        private var controller: AVPictureInPictureController?
        private(set) var isActive = false
        private var events: [String] = []

        init(host: ApplePlayerHost) { self.host = host }

        /// The engine may hand the item to a new player on a rebuild.
        func follow(_ player: AVPlayer?) {
            if let player, layer.player !== player { layer.player = player }
        }

        func start(engine: any ApplePlaybackEngine) async -> [String] {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                  let view = AppleDebugMacCaptionsProbe.playerView(in: window.contentView), let viewLayer = view.layer else {
                return ["CAPTIONS-PROBE pip: no player view"]
            }
            layer.player = engine.avPlayer
            layer.frame = viewLayer.bounds
            layer.videoGravity = .resizeAspect
            viewLayer.insertSublayer(layer, at: 0)
            let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
            controller.delegate = self
            self.controller = controller
            for _ in 0..<40 where !controller.isPictureInPicturePossible {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let possible = controller.isPictureInPicturePossible
            controller.startPictureInPicture()
            for _ in 0..<40 where !isActive { try? await Task.sleep(for: .milliseconds(100)) }
            return ["CAPTIONS-PROBE pip start: possible=\(possible) active=\(controller.isPictureInPictureActive) "
                    + "events=\(drainEvents())"]
        }

        func stop() async -> [String] {
            controller?.stopPictureInPicture()
            for _ in 0..<40 where isActive { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            let line = "CAPTIONS-PROBE pip stop: active=\(controller?.isPictureInPictureActive.description ?? "-") "
                + "events=\(drainEvents())"
            layer.removeFromSuperlayer()
            layer.player = nil
            controller = nil
            return [line]
        }

        private func drainEvents() -> [String] {
            defer { events = [] }
            return events
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(
            _ controller: AVPictureInPictureController
        ) {
            Task { @MainActor in
                self.events.append("didStart")
                self.isActive = true
                self.host.pictureInPictureDidChange(true)
            }
        }

        nonisolated func pictureInPictureControllerWillStopPictureInPicture(
            _ controller: AVPictureInPictureController
        ) {
            Task { @MainActor in
                self.events.append("willStop")
                self.host.pictureInPictureDidChange(false)
            }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(
            _ controller: AVPictureInPictureController
        ) {
            Task { @MainActor in
                self.events.append("didStop")
                self.isActive = false
            }
        }

        nonisolated func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: any Error
        ) {
            let message = error.localizedDescription
            Task { @MainActor in
                self.events.append("failed: \(message)")
                self.host.pictureInPictureDidChange(false)
            }
        }
    }

    /// The item's current video frame, for the reconstructed PiP frame.
    @MainActor
    private final class FrameTap {
        private var output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        private weak var item: AVPlayerItem?

        func attach(to item: AVPlayerItem) {
            guard item !== self.item else { return }
            if let previous = self.item { previous.remove(output) }
            self.item = item
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
        }

        func write(item: AVPlayerItem, caption: [String], to url: URL, log: inout [String]) {
            guard item === self.item,
                  let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else {
                log.append("CAPTIONS-PROBE pip frame: no video frame")
                return
            }
            let frame = CIImage(cvPixelBuffer: buffer)
            let width = Int(frame.extent.width), height = Int(frame.extent.height)
            guard let video = CIContext().createCGImage(frame, from: frame.extent),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(video, in: CGRect(x: 0, y: 0, width: width, height: height))
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 4
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = NSAttributedString(string: caption.joined(separator: "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(height) * 0.05, weight: .semibold),
                .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: style,
            ])
            text.draw(in: CGRect(x: 0, y: CGFloat(height) * 0.06, width: CGFloat(width), height: CGFloat(height) * 0.2))
            NSAttributedString(string: "Reconstructed from AVPlayerItemVideoOutput + AVPlayerItemLegibleOutput (PiP active)",
                               attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white,
                                            .backgroundColor: NSColor.black.withAlphaComponent(0.6)])
                .draw(at: CGPoint(x: 12, y: CGFloat(height) - 28))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? data.write(to: url)) != nil else { return }
            log.append("CAPTIONS-PROBE pip frame: \(url.lastPathComponent) caption=\(caption)")
        }
    }
}
#endif
