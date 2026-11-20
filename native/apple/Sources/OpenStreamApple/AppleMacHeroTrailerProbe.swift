#if DEBUG && os(macOS)
import AppKit
import WebKit

/// `-OpenStreamHeroTrailerProbe </absolute/dir>`: a frame sequence of the Mac
/// hero's trailer around the crossfade, for proving it never changes size or
/// crop once it can be seen (N31, N44). From the first `playing` until
/// `-OpenStreamHeroTrailerProbeSeconds` (default 4) after the cover starts
/// to fade, every 16 ms it writes one line, in WINDOW points from the
/// window's top-left: the window, its safe-area insets, the hero, the art as
/// drawn, the web view, the trailer's picture band, the page's `<video>`,
/// the cover's on-screen opacity, and the part of the art and of the picture
/// the hero shows (`crop=`, as fractions of each). Each trailer the process
/// plays gets its own `probe-N.log`, so a page change or a return from a
/// title page is logged too. It writes `N-before-art.png` (the trailer's
/// cover) and `N-before-still.png` (the hero as the window draws it without
/// the trailer: the SwiftUI still under it, with the fades and copy) once
/// the video plays under the cover, and `N-before-trailer.png` and
/// `N-after-trailer.png` (the hero's part of the web view) at the fade and
/// 0.7 s after it, all at the hero's size.
/// `-OpenStreamHeroTrailerProbeStill <seconds>` also writes `still.png`.
/// `-OpenStreamHeroTrailerProbeResize w,h` resizes the window 1.5 s after
/// the fade, so a resize while the trailer plays is logged;
/// `-OpenStreamHeroTrailerProbeResizeSteps n` gets there in `n` steps a
/// frame apart, as a drag of the window's corner does (N55).
@MainActor
final class AppleMacHeroTrailerProbe {
    weak var container: AppleMacYouTubeHeroPreview.PlayerContainer?
    private let directory: URL
    private var started: Date?
    private var fadeAt: Date?
    private var tick = 0
    private var timer: Timer?
    private var lines = [String]()
    private let number: Int
    private static var count = 0

    private init(directory: URL) {
        self.directory = directory
        Self.count += 1
        number = Self.count
    }

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> AppleMacHeroTrailerProbe? {
        guard let marker = arguments.firstIndex(of: "-OpenStreamHeroTrailerProbe"),
              arguments.indices.contains(marker + 1), arguments[marker + 1].hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: arguments[marker + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppleMacHeroTrailerProbe(directory: directory)
    }

    func begin() {
        guard started == nil else { return }
        started = Date()
        if let screen = NSScreen.main {
            lines.append("SCREEN frame=\(NSStringFromRect(screen.frame)) backingScale=\(screen.backingScaleFactor) layoutScale=\(container?.layoutScale ?? 0)")
        }
        // The art and the still under it are fixed from here to the fade;
        // drawn now, so nothing heavy runs on the main thread at the fade.
        writeArt(named: "\(number)-before-art.png")
        writeHero(named: "\(number)-before-still.png")
        // The web view under the cover from its first frame (`-OpenStreamHeroTrailerProbeFilm YES`),
        // every quarter second for 5 s: what the page draws before the art fades (N70).
        if UserDefaults.standard.bool(forKey: "OpenStreamHeroTrailerProbeFilm") {
            for step in 1...20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.25) { [weak self] in
                    guard let self else { return }
                    let name = "\(self.number)-film-\(String(format: "%04d", step * 250))ms.png"
                    self.container?.webView.evaluateJavaScript(
                        "player && player.getCurrentTime ? player.getCurrentTime() + ' ' + player.getPlaybackQuality() : ''"
                    ) { [weak self] value, _ in
                        self?.lines.append("FILM \(name) media=\(value ?? "?")")
                    }
                    self.writeTrailer(named: name, wholePage: true)
                }
            }
        }
        let still = UserDefaults.standard.double(forKey: "OpenStreamHeroTrailerProbeStill")
        if still > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + still) { [weak self] in self?.writeStill() }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func markFade() {
        guard fadeAt == nil, started != nil else { return }
        sample()
        fadeAt = Date()
        lines.append("FADE at \(milliseconds(since: started))ms")
        writeTrailer(named: "\(number)-before-trailer.png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.writeTrailer(named: "\(self.number)-after-trailer.png")
        }
        let size = (UserDefaults.standard.string(forKey: "OpenStreamHeroTrailerProbeResize") ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if UserDefaults.standard.bool(forKey: "OpenStreamHeroTrailerProbeToolbar") {
            // Full screen hides and shows the toolbar under the pointer;
            // this does the same through the toolbar's own switch.
            for (delay, visible) in [(1.5, false), (2.5, true)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let toolbar = self?.container?.window?.toolbar else { return }
                    self?.lines.append("TOOLBAR visible=\(visible) at \(self?.milliseconds(since: self?.fadeAt) ?? 0)ms after fade")
                    toolbar.isVisible = visible
                }
            }
        }
        if size.count == 2 {
            let steps = max(UserDefaults.standard.integer(forKey: "OpenStreamHeroTrailerProbeResizeSteps"), 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let window = self?.container?.window, let content = window.contentView else { return }
                self?.lines.append("RESIZE to \(Int(size[0]))x\(Int(size[1])) in \(steps) steps at \(self?.milliseconds(since: self?.fadeAt) ?? 0)ms after fade")
                self?.resize(window, from: content.bounds.size, to: CGSize(width: size[0], height: size[1]),
                             step: 1, of: steps)
            }
        }
    }

    /// One step of a stepped resize, then the next a frame later, so each
    /// step is laid out and drawn (and sampled) before the next.
    private func resize(_ window: NSWindow, from: CGSize, to: CGSize, step: Int, of steps: Int) {
        let t = Double(step) / Double(steps)
        window.setContentSize(NSSize(width: (from.width + (to.width - from.width) * t).rounded(),
                                     height: (from.height + (to.height - from.height) * t).rounded()))
        guard step < steps else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self, weak window] in
            guard let self, let window else { return }
            self.sample()
            self.resize(window, from: from, to: to, step: step + 1, of: steps)
        }
    }

    private func milliseconds(since date: Date?) -> Int {
        Int(Date().timeIntervalSince(date ?? Date()) * 1000)
    }

    private var seconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "OpenStreamHeroTrailerProbeSeconds")
        return value > 0 ? value : 4
    }

    private func sample() {
        guard let container, let started else { return finish() }
        let elapsed = Date().timeIntervalSince(started)
        if let fadeAt, Date().timeIntervalSince(fadeAt) > seconds { return finish() }
        if fadeAt == nil, elapsed > 20 { return finish() }
        tick += 1
        lines.append(Self.line(container, tick: tick, elapsed: elapsed,
                               sinceFade: fadeAt.map { milliseconds(since: $0) }))
    }

    /// One tick's geometry, in window points from the top-left.
    static func line(_ container: AppleMacYouTubeHeroPreview.PlayerContainer, tick: Int, elapsed: TimeInterval,
                     sinceFade: Int?) -> String {
        let window = container.window
        let contentHeight = window?.contentView?.bounds.height ?? 0
        func inWindow(_ rect: CGRect, of view: NSView) -> CGRect {
            let r = view.convert(rect, to: nil)
            return CGRect(x: r.minX, y: contentHeight - r.maxY, width: r.width, height: r.height)
        }
        func text(_ r: CGRect?) -> String {
            guard let r else { return "none" }
            return String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height)
        }
        func fraction(_ r: CGRect?) -> String {
            guard let r else { return "none" }
            return String(format: "%.3f,%.3f %.3fx%.3f", r.minX, r.minY, r.width, r.height)
        }
        let hero = inWindow(container.bounds, of: container)
        let art = container.coverImageSize.map {
            inWindow(AppleTrailerPreviewLayout.aspectFillFrame(of: $0, in: container.bounds.size), of: container)
        }
        let web = inWindow(container.webView.bounds, of: container.webView)
        let band = container.pictureWindow
        let picture = CGRect(x: web.minX, y: web.minY + web.height * band.lowerBound,
                             width: web.width, height: web.height * (band.upperBound - band.lowerBound))
        let insets = window?.contentView?.safeAreaInsets ?? NSEdgeInsetsZero
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        return String(
            format: "tick=%04d t=%dms sinceFade=%@ cover=%.2f win=%@%@ safe=%.0f,%.0f,%.0f,%.0f hero=%@ art=%@ web=%@ pic=%@ crop.art=%@ crop.pic=%@ zoom=%@",
            tick, Int(elapsed * 1000), sinceFade.map(String.init) ?? "-", container.coverOpacity,
            text(window?.frame), fullScreen ? "(fs)" : "",
            insets.top, insets.left, insets.bottom, insets.right,
            text(hero), text(art), text(web), text(picture),
            fraction(art.map { AppleMacHeroCrop.visibleFraction(of: $0, through: hero) }),
            fraction(AppleMacHeroCrop.visibleFraction(of: picture, through: hero)),
            art.map { String(format: "%.3f", picture.width / max($0.width, 1)) } ?? "none")
    }

    /// The hero's part of the art, as it is drawn, at the hero's size.
    private func writeArt(named name: String) {
        guard let container, let image = container.coverImage, let size = container.coverImageSize else { return }
        let bounds = container.bounds
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var fill = AppleTrailerPreviewLayout.aspectFillFrame(of: size, in: bounds.size)
        fill.origin.y = bounds.height - fill.maxY // CoreGraphics draws from the bottom.
        context.draw(image, in: fill)
        guard let cropped = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?
            .write(to: directory.appending(path: name))
    }

    /// The hero as the window draws it with the trailer's container
    /// hidden: the SwiftUI still under it, with the hero's fades and copy.
    private func writeHero(named name: String) {
        guard let container, let frame = container.window?.contentView?.superview else { return }
        let hero = container.convert(container.bounds, to: frame)
        container.isHidden = true
        defer { container.isHidden = false }
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: hero) else { return }
        frame.cacheDisplay(in: hero, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: name))
    }

    /// The hero's part of the web view, at the hero's size.
    /// `wholePage` keeps the parts the hero crops away (the film: nothing
    /// YouTube draws at the page's edges either).
    private func writeTrailer(named name: String, wholePage: Bool = false) {
        guard let container else { return }
        let web = container.webView.frame
        let visible = wholePage ? CGRect(origin: .zero, size: web.size)
            : container.bounds.offsetBy(dx: -web.minX, dy: -web.minY)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(web.width))
        let directory = directory
        container.webView.takeSnapshot(with: configuration) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), web.width > 0 else { return }
            let factor = CGFloat(cg.width) / web.width
            let crop = CGRect(x: visible.minX * factor, y: visible.minY * factor,
                              width: visible.width * factor, height: visible.height * factor).integral
            guard let cropped = cg.cropping(to: crop) else { return }
            try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: name))
        }
    }

    private func writeStill() {
        guard let container else { return }
        let web = container.webView.frame
        let visible = container.bounds.offsetBy(dx: -web.minX, dy: -web.minY)
        let directory = directory
        container.webView.evaluateJavaScript("player && player.getCurrentTime ? player.getCurrentTime() : -1") { time, _ in
            appleTrace("probe still at mediaTime=\(time ?? "?")")
        }
        container.webView.takeSnapshot(with: nil) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), web.width > 0 else { return }
            let factor = CGFloat(cg.width) / web.width
            let crop = CGRect(x: visible.minX * factor, y: visible.minY * factor,
                              width: visible.width * factor, height: visible.height * factor).integral
            guard let cropped = cg.cropping(to: crop) else { return }
            try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "still.png"))
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        guard !lines.isEmpty else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "probe-\(number).log"),
                                                          atomically: true, encoding: .utf8)
        lines.removeAll()
    }
}
#endif
