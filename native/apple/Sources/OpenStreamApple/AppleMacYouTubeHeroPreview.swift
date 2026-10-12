#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// The Mac hero's inline trailer: the same muted YouTube preview page the
/// iPhone and iPad draw (`AppleYouTubePreviewHTML`), in a web view that never
/// takes a click, under a cover of the hero's own still that fades away only
/// once the video has frames — so the hero shows its art, never a black
/// iframe, until the trailer is really playing.
///
/// The web view is laid out at exactly the still's geometry — the art's
/// aspect-fill scale about the same centre (`AppleTrailerPreviewLayout
/// .artMatchedFrame`), the still under it centred to match — and never
/// re-sized while the video is on screen, so the crossfade from the art to
/// its trailer never reads as a zoom (N30, N44). The cover fades only once
/// YouTube has laid its video out at that size and held it (N31). It
/// reports only that frame to SwiftUI: a window resize moves it in place
/// and never reloads the page.
@MainActor
struct AppleMacYouTubeHeroPreview: NSViewRepresentable {
    let url: URL
    /// The hero's decoded still, shown until the first frame.
    var artworkImage: CGImage?
    let isPlaying: Bool
    let isMuted: Bool
    let onStateChange: (String, Bool, Int?) -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loadedURL: URL?
        var lastMuted = true
        var lastPlaying = true
        /// What the loaded document was told to start with. A change that
        /// arrives before the page has loaded is evaluated against the old
        /// document and lost, so `ready` sends whatever differs again.
        var documentPlaying = true
        var documentMuted = true
        var onStateChange: ((String, Bool, Int?) -> Void)?
        weak var container: PlayerContainer?
        private var revealGeneration = 0
        /// What YouTube's player page last reported, and when it changed.
        private(set) var geometry: AppleMacTrailerGeometry?
        private var geometryChangedAt = Date.distantPast

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "trailerState",
                  let payload = message.body as? [String: Any],
                  let state = payload["state"] as? String else { return }
            if state == "geometry" {
                let reported = AppleMacTrailerGeometry(payload: payload)
                if reported != geometry {
                    geometry = reported
                    geometryChangedAt = Date()
                }
                return
            }
            #if DEBUG
            if state == "playing" { container?.probe?.begin() }
            #endif
            if state == "ready" {
                // The title page starts its trailer a moment after the view
                // is made; without this the page stayed on `ready` with the
                // still up (Mac trace, 2026-09-24).
                if lastPlaying != documentPlaying {
                    documentPlaying = lastPlaying
                    container?.webView.evaluateJavaScript(
                        "window.setTrailerPlaying(\(lastPlaying ? "true" : "false"));", completionHandler: nil)
                }
                if lastMuted != documentMuted {
                    documentMuted = lastMuted
                    container?.webView.evaluateJavaScript(
                        AppleTrailerSoundBridge.javascriptCommand(isMuted: lastMuted), completionHandler: nil)
                    appleTrace("mac hero trailer state=ready muted=\(lastMuted) error=none (re-sent)")
                    onStateChange?(state, lastMuted, nil)
                    return
                }
            }
            let muted = payload["muted"] as? Bool ?? lastMuted
            lastMuted = muted
            let errorCode = payload["errorCode"] as? Int
            let quality = (payload["quality"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            appleTrace("mac hero trailer state=\(state) muted=\(muted) quality=\(quality) error=\(errorCode.map(String.init) ?? "none")")
            switch state {
            case "revealed":
                // Said once the cover starts to fade, so the hero's fade and
                // mute button change with the crossfade, not before it.
                reveal { [weak self] in self?.onStateChange?(state, muted, errorCode) }
                return
            case "ended":
                // The page pauses only once the art has crossfaded back up,
                // so the fade runs over live frames.
                conceal(animated: true) { [weak self] in
                    self?.container?.webView.evaluateJavaScript("window.completeTrailerEnd();", completionHandler: nil)
                }
            case "error":
                conceal(animated: true)
            case "paused", "concealed":
                conceal()
            default:
                break
            }
            onStateChange?(state, muted, errorCode)
        }

        /// WebKit's content process died under the trailer: the dead page
        /// draws nothing, so the still crossfades back over it and the
        /// caller drops the video layer. Nothing reloads here: a page that
        /// crashed once is not retried.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            appleTrace("mac hero trailer web content process terminated")
            conceal(animated: true)
            onStateChange?(AppleTrailerArtFirstPolicy.webContentTerminatedState, lastMuted, nil)
        }

        /// A new page reports afresh; the old one's size must not settle it.
        func forgetGeometry() {
            geometry = nil
            geometryChangedAt = .distantPast
        }

        func conceal(animated: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil) {
            revealGeneration += 1
            container?.setPreviewVisible(false, animated: animated, completion: completion)
        }

        /// Looks for a real picture first: a frame that measures as nothing
        /// (a fade-in, a title card) is looked at again a second later, up
        /// to three times, with the art still up. The web view is laid
        /// out again so the band it finds covers the hero (N62: the owner
        /// saw a letterboxed trailer's mattes as black bands). Then it waits for YouTube to lay its video out at the web
        /// view's size and hold it, so the geometry is settled before the
        /// video is seen and never changes under it.
        private func reveal(then revealed: @escaping () -> Void) {
            guard let container else { return }
            revealGeneration += 1
            let generation = revealGeneration
            measure(container, generation: generation, remaining: 3) { [weak self] container in
                self?.settle(container, generation: generation, since: Date()) { container in
                    container.setPreviewVisible(true)
                    revealed()
                }
            }
        }

        /// Resizing a web view is asynchronous twice over: WebKit lays the
        /// page out again, then YouTube's player re-sizes its `<video>` a few
        /// frames later. Faded over that, the picture showed at its old size
        /// and then grew (owner, N31). Polls until the player page reports
        /// the web view's size with its video fitted to it, unchanged for
        /// `AppleMacTrailerSettlePolicy.stableInterval`; gives up and reveals
        /// after `timeout` rather than never show the trailer.
        private func settle(_ container: PlayerContainer, generation: Int, since start: Date,
                            then: @escaping (PlayerContainer) -> Void) {
            guard revealGeneration == generation else { return }
            let expected = CGSize(width: container.webView.frame.width * CGFloat(container.layoutScale),
                                  height: container.webView.frame.height * CGFloat(container.layoutScale))
            let now = Date()
            let settled = AppleMacTrailerSettlePolicy.isSettled(geometry, expected: expected)
                && now.timeIntervalSince(geometryChangedAt) >= AppleMacTrailerSettlePolicy.stableInterval
            #if DEBUG
            let skips = UserDefaults.standard.bool(forKey: "OpenStreamHeroNoSettle")
            #else
            let skips = false
            #endif
            let timedOut = now.timeIntervalSince(start) >= AppleMacTrailerSettlePolicy.timeout
            if settled || timedOut || skips {
                let verdict = settled ? "settled" : skips ? "not awaited" : "unsettled"
                appleTrace("mac hero trailer geometry \(verdict) after \(Int(now.timeIntervalSince(start) * 1000))ms expected=\(Int(expected.width))x\(Int(expected.height)) \(geometry?.description ?? "none")")
                then(container)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak container] in
                guard let self, let container else { return }
                self.settle(container, generation: generation, since: start, then: then)
            }
        }

        private func measure(_ container: PlayerContainer, generation: Int, remaining: Int,
                             then: @escaping (PlayerContainer) -> Void) {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            configuration.snapshotWidth = NSNumber(value: 256)
            container.webView.takeSnapshot(with: configuration) { [weak self, weak container] image, _ in
                guard let self, let container, self.revealGeneration == generation else { return }
                let window = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    .flatMap(AppleTrailerPreviewLayout.pictureWindow(in:))
                if let window {
                    container.pictureWindow = window
                    container.hasMeasuredPicture = true
                    appleTrace(String(format: "mac hero trailer picture band %.3f...%.3f", window.lowerBound, window.upperBound))
                }
                guard !container.hasMeasuredPicture, remaining > 0 else {
                    // Laid out at the art's frame before the cover fades.
                    container.layoutSubtreeIfNeeded()
                    then(container)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak container] in
                    guard let self, let container, self.revealGeneration == generation else { return }
                    self.measure(container, generation: generation, remaining: remaining - 1, then: then)
                }
            }
        }
    }

    final class PlayerContainer: NSView {
        let webView: WKWebView
        private let cover = CoverView()
        /// The picture band last measured inside the 16:9 raster (the
        /// trailer's own mattes outside it). The web view is laid out so
        /// the band covers the hero: no black bands above and below a
        /// letterboxed trailer (N62).
        var pictureWindow: ClosedRange<CGFloat> = 0...1 {
            didSet { if pictureWindow != oldValue { needsLayout = true } }
        }
        var hasMeasuredPicture = false
        /// How many times the web view's size the page lays YouTube out at.
        var layoutScale = 1
        private var previewVisible = false
        #if DEBUG
        let probe = AppleMacHeroTrailerProbe.fromArguments()
        /// Read by the probe each tick.
        var geometry: () -> AppleMacTrailerGeometry? = { nil }
        var coverOpacity: Float { cover.layer?.presentation()?.opacity ?? cover.layer?.opacity ?? -1 }
        var coverImage: CGImage? { cover.image }
        var coverImageSize: CGSize? { cover.imageSize }
        #endif

        init(messageHandler: WKScriptMessageHandler) {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(WKUserScript(
                source: ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            configuration.userContentController.addUserScript(WKUserScript(
                source: AppleYouTubePreviewHTML.macPlayerFrameScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            configuration.userContentController.add(messageHandler, name: "trailerState")
            webView = WKWebView(frame: .zero, configuration: configuration)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            webView.setAccessibilityElement(false)
            addSubview(webView)
            addSubview(cover)
            #if DEBUG
            probe?.container = self
            // WebKit stops drawing a web view whose window is hidden; a
            // test copy measured while the display sleeps keeps it drawing.
            // Called through its implementation, never KVC: an unknown key
            // throws an Objective-C exception that ends the app (N44's test
            // copies crashed that way, 2026-09-25 02:12-02:22).
            let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if UserDefaults.standard.bool(forKey: "OpenStreamMacAssumeVisible"),
               let method = class_getInstanceMethod(type(of: webView), occlusion) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, occlusion, false)
            }
            #endif
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        /// The hero's own buttons, hover and swipe handle every event; the
        /// iframe never gets a click it could act on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            webView.frame = AppleTrailerPreviewLayout.artMatchedFrame(
                in: bounds.size, art: cover.imageSize, pictureWindow: pictureWindow)
            cover.frame = bounds
        }

        func updateStill(_ image: CGImage?) {
            let size = cover.imageSize
            cover.image = image
            if cover.imageSize != size { needsLayout = true }
        }

        /// Reveal cross-fades the cover away over the live frames. Hiding
        /// crossfades it back when `animated` (a trailer that ends or fails)
        /// and puts it back at once otherwise; `completion` runs once the
        /// art is fully up. Reduce Motion swaps instantly both ways.
        func setPreviewVisible(_ visible: Bool, animated: Bool = true,
                               completion: (@MainActor @Sendable () -> Void)? = nil) {
            let wasVisible = previewVisible
            previewVisible = visible
            if visible != wasVisible { appleTrace("mac hero trailer cover \(visible ? "fading out" : "up")") }
            #if DEBUG
            if visible, !wasVisible { probe?.markFade() }
            #endif
            let duration = AppleTrailerArtFirstPolicy.crossfadeDuration(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            let animates = visible != wasVisible && animated && duration > 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animates ? duration : 0
                context.allowsImplicitAnimation = animates
                cover.animator().alphaValue = visible ? 0 : 1
            } completionHandler: {
                // AppKit runs it on the main thread.
                MainActor.assumeIsolated { completion?() }
            }
        }
    }

    /// The still, drawn aspect-fill as the hero draws it.
    final class CoverView: NSView {
        var image: CGImage? {
            didSet { if image !== oldValue { needsDisplay = true } }
        }
        var imageSize: CGSize? { image.map { CGSize(width: $0.width, height: $0.height) } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.contents = image
            layer?.contentsGravity = .resizeAspectFill
            layer?.backgroundColor = image == nil ? NSColor.black.cgColor : nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainer {
        let coordinator = context.coordinator
        coordinator.onStateChange = onStateChange
        coordinator.lastMuted = isMuted
        coordinator.lastPlaying = isPlaying
        let container = PlayerContainer(messageHandler: coordinator)
        container.webView.navigationDelegate = coordinator
        coordinator.container = container
        #if DEBUG
        container.geometry = { [weak coordinator] in coordinator?.geometry }
        #endif
        container.updateStill(artworkImage)
        load(url, in: container, context: context)
        return container
    }

    func updateNSView(_ view: PlayerContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.onStateChange = onStateChange
        view.updateStill(artworkImage)
        if coordinator.loadedURL != url {
            view.pictureWindow = 0...1
            view.hasMeasuredPicture = false
            coordinator.conceal()
            load(url, in: view, context: context)
        }
        if coordinator.lastPlaying != isPlaying {
            coordinator.lastPlaying = isPlaying
            if !isPlaying { coordinator.conceal() }
            view.webView.evaluateJavaScript("window.setTrailerPlaying(\(isPlaying ? "true" : "false"));", completionHandler: nil)
        }
        if coordinator.lastMuted != isMuted {
            coordinator.lastMuted = isMuted
            view.webView.evaluateJavaScript(AppleTrailerSoundBridge.javascriptCommand(isMuted: isMuted), completionHandler: nil)
        }
    }

    static func dismantleNSView(_ view: PlayerContainer, coordinator: Coordinator) {
        coordinator.conceal()
        view.webView.evaluateJavaScript("window.setTrailerPlaying(false);", completionHandler: nil)
        view.webView.stopLoading()
        view.webView.loadHTMLString("", baseURL: nil)
        view.webView.configuration.userContentController.removeScriptMessageHandler(forName: "trailerState")
        coordinator.loadedURL = nil
        coordinator.onStateChange = nil
    }

    private func load(_ url: URL, in view: PlayerContainer, context: Context) {
        context.coordinator.loadedURL = url
        context.coordinator.documentPlaying = isPlaying
        context.coordinator.documentMuted = isMuted
        context.coordinator.forgetGeometry()
        view.layoutScale = Self.layoutScale(displayScale: context.environment.displayScale)
        appleTrace("mac hero trailer load playing=\(isPlaying) muted=\(isMuted) layoutScale=\(view.layoutScale)")
        let html = AppleYouTubePreviewHTML.document(
            embedURL: url, startsPlaying: isPlaying, isLandscape: true, startsMuted: isMuted, allowsSound: true,
            layoutScale: view.layoutScale
        )
        view.webView.loadHTMLString(html, baseURL: URL(string: "https://openstream.app"))
    }

    /// `AppleTrailerPreviewPolicy.macLayoutScale`; a DEBUG build takes
    /// `-OpenStreamHeroLayoutScale 1` to compare against the unscaled page.
    static func layoutScale(displayScale: CGFloat) -> Int {
        #if DEBUG
        let forced = UserDefaults.standard.integer(forKey: "OpenStreamHeroLayoutScale")
        if forced > 0 { return forced }
        #endif
        return AppleTrailerPreviewPolicy.macLayoutScale(displayScale: Double(displayScale))
    }
}

/// Where YouTube's player page draws, as its injected script reports it
/// (`AppleYouTubePreviewHTML.macPlayerFrameScript`), in the page's CSS px.
struct AppleMacTrailerGeometry: Equatable, CustomStringConvertible {
    var frame: CGSize
    var video: CGRect?

    init(frame: CGSize, video: CGRect?) {
        self.frame = frame
        self.video = video
    }

    init?(payload: [String: Any]) {
        guard let frame = payload["frame"] as? [Double], frame.count == 2 else { return nil }
        self.frame = CGSize(width: frame[0], height: frame[1])
        if let video = payload["video"] as? [Double], video.count == 4 {
            self.video = CGRect(x: video[0], y: video[1], width: video[2], height: video[3])
        }
    }

    var description: String {
        let box = video.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        return "frame=\(Int(frame.width))x\(Int(frame.height)) video=\(box)"
    }
}

enum AppleMacTrailerSettlePolicy {
    /// The picture must hold its final place this long before the art fades.
    static let stableInterval: TimeInterval = 0.3
    /// Reveals anyway after this, rather than never show the trailer.
    static let timeout: TimeInterval = 3
    /// CSS px of rounding between the web view's points and the page.
    static let tolerance: CGFloat = 3

    /// The player page is `expected` (the web view's size in the page's CSS
    /// px) and its video is fitted to it — filling one axis, centred, inside
    /// it. A video still at the old size while the page has grown fits no
    /// axis, which is the moment the art must not fade over.
    static func isSettled(_ geometry: AppleMacTrailerGeometry?, expected: CGSize) -> Bool {
        guard let geometry, let video = geometry.video, video.width > 0, video.height > 0 else { return false }
        let frame = geometry.frame
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        return near(frame.width, expected.width) && near(frame.height, expected.height)
            && (near(video.width, frame.width) || near(video.height, frame.height))
            && video.width <= frame.width + tolerance && video.height <= frame.height + tolerance
            && near(video.midX, frame.width / 2) && near(video.midY, frame.height / 2)
    }
}
#endif
