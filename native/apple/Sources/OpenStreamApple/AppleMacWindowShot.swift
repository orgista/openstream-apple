#if DEBUG && os(macOS)
import AppKit
import AVKit
import WebKit

/// Renders the app's own window to a PNG, and dumps the menu bar, on request
/// from a launch argument.
///
/// This exists because a macOS screenshot could not be taken from a headless
/// session at all, and the repo had concluded it was impossible
/// (`HANDOFF-NEXT-SESSION.md:324`). `screencapture -x` returns the wallpaper
/// with every window erased without a Screen Recording grant, `-l<windowid>`
/// and `-R` fail outright, ScreenCaptureKit is refused
/// (`SCStreamErrorDomain -3801`), and XCUITest needs an Accessibility grant
/// that cannot be given non-interactively.
///
/// None of that applies to an app drawing itself. `cacheDisplay(in:to:)` is
/// the app rendering its own layer tree into its own bitmap: no TCC grant, no
/// window ever brought to the front, and nothing of anyone else's screen in
/// the frame. The previous session drove this from lldb; lldb's Objective-C
/// evaluator has no AppKit headers, so `NSMakeRect` and `stringWithFormat:`
/// are both unavailable there and the expression is a liability. In the app it
/// is ordinary code.
///
/// DEBUG and macOS only, behind an explicit launch argument, so a shipped
/// build has no path to it.
public enum AppleMacWindowShot {
    public struct Request {
        /// A bare filename. It is written inside the app's own container, the
        /// only place a sandboxed app may write without a user's consent; the
        /// caller copies it out.
        public let filename: String
        public let size: CGSize
        public let delay: TimeInterval
        /// Set by `-OpenStreamSnapshotWindow`: an absolute path to write the
        /// PNG to instead, for an unsandboxed debug build a script launched.
        public var destination: URL? = nil
        /// `-OpenStreamWindowShotThenKey escape|commandW|space|zoomFlag[,…]`:
        /// after the shot, post those keys to the window through the app's own
        /// event queue, reporting each, and take a second shot beside the
        /// first (`….after.png`). How the Mac player's Esc and ⌘W are proven
        /// without driving the screen.
        public var thenKey: String? = nil
        /// `-OpenStreamWindowShotAgainAfter <seconds>`: a second shot that
        /// much later in the same launch (`….later.png`), untouched — how
        /// the hero's art and then its trailer are shown on the same page.
        public var againAfter: TimeInterval? = nil
    }

    /// `-OpenStreamWindowShot <name.png> [-OpenStreamWindowShotSize 1280x860]
    ///  [-OpenStreamWindowShotDelay 11]`, or
    /// `-OpenStreamSnapshotWindow </absolute/path.png>` (12 s by default, the
    /// same size and delay flags).
    public static func request(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Request? {
        let size = value(of: "-OpenStreamWindowShotSize", in: arguments)
            .flatMap(parseSize) ?? CGSize(width: 1280, height: 860)
        let delay = value(of: "-OpenStreamWindowShotDelay", in: arguments).flatMap(Double.init)
        if let path = value(of: "-OpenStreamSnapshotWindow", in: arguments),
           path.hasPrefix("/"), path.lowercased().hasSuffix(".png") {
            let destination = URL(fileURLWithPath: path)
            return Request(filename: destination.lastPathComponent, size: size, delay: delay ?? 12,
                           destination: destination,
                           thenKey: value(of: "-OpenStreamWindowShotThenKey", in: arguments),
                           againAfter: value(of: "-OpenStreamWindowShotAgainAfter", in: arguments).flatMap(Double.init))
        }
        guard let name = value(of: "-OpenStreamWindowShot", in: arguments),
              !name.isEmpty, !name.contains("/") else { return nil }
        return Request(filename: name, size: size, delay: delay ?? 11,
                       againAfter: value(of: "-OpenStreamWindowShotAgainAfter", in: arguments).flatMap(Double.init))
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let marker = arguments.firstIndex(of: flag),
              arguments.indices.contains(marker + 1) else { return nil }
        return arguments[marker + 1]
    }

    static func parseSize(_ value: String) -> CGSize? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              w >= 200, h >= 200, w <= 8_000, h <= 8_000 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Waits out `delay`, resizes the window, renders it, writes it, and
    /// reports on stderr. stderr because a GUI app launched from a script has
    /// a pipe on stdout, where a handful of lines stay in the block buffer of
    /// a process that never exits.
    @MainActor
    public static func run(_ request: Request) async {
        // A breadcrumb before the wait, so a run that produces nothing can be
        // told apart from a run that never started. Without it, "no window
        // yet", "the argument did not parse" and "the scene never built its
        // content" all look identical from outside: an empty directory.
        write("OPENSTREAM-SHOT started delay=\(request.delay) size=\(Int(request.size.width))x\(Int(request.size.height))\n",
              to: "shot-start.log")
        try? await Task.sleep(for: .seconds(request.delay))
        var lines = [String]()
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else {
            emit(["OPENSTREAM-SHOT verdict: no window with a content view"])
            return
        }
        for candidate in NSApp.windows {
            lines.append("OPENSTREAM-SHOT candidate: \(candidate.className) visible=\(candidate.isVisible) sheet=\(candidate.attachedSheet != nil) frame=\(NSStringFromRect(candidate.frame))")
        }
        window.setFrame(
            NSRect(origin: window.frame.origin, size: request.size),
            display: true
        )
        // One turn of the run loop so SwiftUI lays the new size out before the
        // shutter; without it the image is the pre-resize frame.
        await Task.yield()
        try? await Task.sleep(for: .seconds(2))

        lines.append("OPENSTREAM-SHOT window: \(window.className) frame=\(NSStringFromRect(window.frame))")
        lines.append("OPENSTREAM-SHOT styleMask resizable=\(window.styleMask.contains(.resizable)) fullScreenPrimary=\(window.collectionBehavior.contains(.fullScreenPrimary))")
        lines.append("OPENSTREAM-SHOT subviews: \(window.contentView?.subviews.count ?? -1)")
        lines.append(titlebarState(window))

        // A sheet is its own `NSWindow`, so a player or an importer presented
        // over the main window is not in the main window's layer tree at all —
        // the first attempt at capturing local playback photographed the Add
        // Files page the player had covered (2026-09-21). The base window is
        // still the one that gets resized; the sheet is captured at whatever
        // size it chose.
        let target = window.attachedSheet ?? window
        if target !== window {
            lines.append("OPENSTREAM-SHOT capturing the attached sheet: \(target.className)")
        }

        // `contentView.superview` is the NSThemeFrame, so the titlebar is in
        // the frame — which on macOS is where SwiftUI puts the tab bar.
        guard let frameView = target.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            emit(lines + ["OPENSTREAM-SHOT verdict: could not make a bitmap rep"])
            return
        }
        // A web view (the hero's trailer) draws out of process and comes out
        // black in `cacheDisplay`; its own snapshot stands in for it, in its
        // place under whatever SwiftUI draws over it, for the one frame.
        let (standIns, webLines) = await standInsForWebViews(in: frameView)
        lines.append(contentsOf: webLines)
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        standIns.forEach { $0.removeFromSuperview() }
        lines.append(contentsOf: drawPopovers(over: target, into: rep))
        guard let data = rep.representation(using: .png, properties: [:]) else {
            emit(lines + ["OPENSTREAM-SHOT verdict: PNG encoding failed"])
            return
        }
        let url = request.destination ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: request.filename)
        do {
            try data.write(to: url, options: .atomic)
            lines.append("OPENSTREAM-SHOT path: \(url.path)")
            lines.append("OPENSTREAM-SHOT bytes: \(data.count)")
            lines.append("OPENSTREAM-SHOT distinctColours: \(distinctColours(in: rep))")
        } catch {
            lines.append("OPENSTREAM-SHOT verdict: write failed \(error)")
            emit(lines)
            return
        }
        lines.append(contentsOf: menuDump())
        lines.append(contentsOf: menuDumpAfterUpdate())
        if let againAfter = request.againAfter {
            try? await Task.sleep(for: .seconds(againAfter))
            let later = url.deletingPathExtension().appendingPathExtension("later.png")
            let (laterStandIns, laterWebLines) = await standInsForWebViews(in: frameView)
            lines.append(contentsOf: laterWebLines)
            if let laterRep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: laterRep)
                if let data = laterRep.representation(using: .png, properties: [:]),
                   (try? data.write(to: later, options: .atomic)) != nil {
                    lines.append("OPENSTREAM-SHOT later path: \(later.path)")
                }
            }
            laterStandIns.forEach { $0.removeFromSuperview() }
        }
        if let thenKeys = request.thenKey {
            // Comma-separated: every key but the last is pressed and reported;
            // the last one is followed by the second shot.
            let keys = thenKeys.split(separator: ",").map(String.init)
            for key in keys.dropLast() {
                lines.append(contentsOf: await press(key, in: window))
            }
            if let last = keys.last {
                lines.append(contentsOf: await pressThenCapture(last, in: window, besides: url))
            }
        }
        lines.append("OPENSTREAM-SHOT verdict: PASS")
        emit(lines)
    }

    /// What the title bar is doing: whether the toolbar is up and the
    /// traffic lights are there to click.
    @MainActor
    private static func titlebarState(_ window: NSWindow) -> String {
        let close = window.standardWindowButton(.closeButton)
        return "OPENSTREAM-SHOT titlebar: titled=\(window.styleMask.contains(.titled)) "
            + "fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) "
            + "toolbarVisible=\(window.toolbar?.isVisible.description ?? "none") "
            + "closeButton=\(close == nil ? "none" : "hidden=\(close!.isHidden) alpha=\(close!.alphaValue) inWindow=\(close!.window != nil)") "
            + "titlebarAppearsTransparent=\(window.titlebarAppearsTransparent)"
            + chain(from: close)
    }

    @MainActor
    private static func chain(from view: NSView?) -> String {
        var parts: [String] = []
        var current = view?.superview
        while let view = current {
            parts.append("\(type(of: view))(hidden=\(view.isHidden) alpha=\(view.alphaValue) layerOpacity=\(view.layer?.opacity ?? -1))")
            current = view.superview
        }
        return " chain=" + parts.joined(separator: " < ")
    }

    /// Posts `key` to `window` as a real key-down event — it goes through
    /// `sendEvent`, the local monitors and the menu bar exactly as a key press
    /// does — then renders the window again.
    @MainActor
    private static func press(_ key: String, in window: NSWindow) async -> [String] {
        // A key equivalent posted to an app in the background never reaches
        // the menu bar, and bringing it forward would take the owner's focus.
        // `zoomFlag` flips what View ▸ Zoom to Fill flips, directly.
        if key == "zoomFlag" {
            AppleMacCommandCenter.shared.zoomToFill.toggle()
            try? await Task.sleep(for: .seconds(1))
            return [report(key, in: window)]
        }
        let (characters, keyCode, modifiers): (String, UInt16, NSEvent.ModifierFlags) = switch key {
        case "commandW": ("w", 13, .command)
        case "space": (" ", 49, [])
        default: ("\u{1b}", 53, [])
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else {
            return ["OPENSTREAM-SHOT press: could not make the \(key) event"]
        }
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(for: .seconds(2))
        return [report(key, in: window)]
    }

    @MainActor
    private static func report(_ key: String, in window: NSWindow) -> String {
        let gravity = playerViews(in: window.contentView).map(\.videoGravity.rawValue)
        let rates = playerViews(in: window.contentView).map {
            "\($0.player?.rate ?? -1)@\(Int($0.player?.currentTime().seconds ?? -1))s"
        }
        let centre = AppleMacCommandCenter.shared
        return "OPENSTREAM-SHOT pressed \(key): zoomToFill=\(centre.zoomToFill) playerGravity=\(gravity) "
            + "rate=\(rates) canControlPlayback=\(centre.canControlPlayback) onStage=\(centre.isPlayerOnStage) "
            + "firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
    }

    @MainActor
    private static func playerViews(in view: NSView?) -> [AVPlayerView] {
        guard let view else { return [] }
        if let player = view as? AVPlayerView { return [player] }
        return view.subviews.flatMap { playerViews(in: $0) }
    }

    @MainActor
    private static func pressThenCapture(_ key: String, in window: NSWindow, besides url: URL) async -> [String] {
        let pressed = await press(key, in: window)
        var lines = pressed + ["OPENSTREAM-SHOT after \(key): window visible=\(window.isVisible) windows=\(NSApp.windows.filter(\.isVisible).count)",
                     titlebarState(window)]
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return lines + ["OPENSTREAM-SHOT after: could not make a bitmap rep"]
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let after = url.deletingPathExtension().appendingPathExtension("after.png")
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: after, options: .atomic)) != nil {
            lines.append("OPENSTREAM-SHOT after path: \(after.path)")
        }
        return lines
    }

    @MainActor
    private static func standInsForWebViews(in root: NSView) async -> ([NSView], [String]) {
        var webViews = [WKWebView]()
        var pending = [root]
        while let view = pending.popLast() {
            if let webView = view as? WKWebView { webViews.append(webView) } else { pending.append(contentsOf: view.subviews) }
        }
        var added = [NSView]()
        var lines = [String]()
        for webView in webViews where !webView.isHiddenOrHasHiddenAncestor {
            guard let image = try? await webView.takeSnapshot(configuration: nil),
                  let superview = webView.superview else { continue }
            let standIn = NSImageView(frame: webView.frame)
            standIn.image = image
            standIn.imageScaling = .scaleAxesIndependently
            superview.addSubview(standIn, positioned: .above, relativeTo: webView)
            added.append(standIn)
            lines.append("OPENSTREAM-SHOT web view stand-in: \(NSStringFromRect(webView.frame))")
        }
        return (added, lines)
    }

    /// A popover (the title page's season list) is a window of its own over
    /// the main one, so the main window's layer tree does not have it. Each
    /// visible one is rendered the same way and drawn in where it sits.
    @MainActor
    private static func drawPopovers(over window: NSWindow, into rep: NSBitmapImageRep) -> [String] {
        let popovers = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.className.contains("Popover") && $0.frame.intersects(window.frame)
        }
        guard !popovers.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
        var lines = [String]()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for popover in popovers {
            guard let view = popover.contentView?.superview,
                  let popoverRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: popoverRep)
            // Both frames are in screen points with the origin bottom-left,
            // as the bitmap context is.
            let origin = CGPoint(x: popover.frame.minX - window.frame.minX, y: popover.frame.minY - window.frame.minY)
            popoverRep.draw(in: NSRect(origin: origin, size: popover.frame.size), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            lines.append("OPENSTREAM-SHOT popover: \(popover.className) frame=\(NSStringFromRect(popover.frame))")
        }
        NSGraphicsContext.restoreGraphicsState()
        return lines
    }

    /// A blank window is the failure this whole exercise started from, and a
    /// PNG of one is a perfectly valid PNG. One distinct colour means blank.
    private static func distinctColours(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 120)
        let stepY = max(1, rep.pixelsHigh / 120)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let key = UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                seen.insert(key)
                if seen.count > 64 { return seen.count }
            }
        }
        return seen.count
    }

    /// Every menu, item and key equivalent the app declares.
    ///
    /// The macOS sweep's menu-bar row could only be answered by reading the
    /// real `NSApp.mainMenu`, because what SwiftUI does with a `.commands`
    /// block is not obvious from the source — an auto-generated "Toggle
    /// Sidebar ⌘S" was landing in *Help*.
    @MainActor
    public static func menuDump(prefix: String = "OPENSTREAM-MENU") -> [String] {
        guard let main = NSApp.mainMenu else { return ["\(prefix) mainMenu: nil"] }
        var lines = ["\(prefix) menus: \(main.items.count)"]
        for menu in main.items {
            let submenu = menu.submenu
            lines.append("\(prefix) [\(menu.title)] items=\(submenu?.items.count ?? 0)")
            for item in submenu?.items ?? [] {
                if item.isSeparatorItem { continue }
                let key = item.keyEquivalent.isEmpty
                    ? ""
                    : "  key=\(modifierString(item.keyEquivalentModifierMask))\(printable(item.keyEquivalent))"
                // The selector shows which items are AppKit's own (the stock
                // full-screen item is `toggleFullScreen:`) and which SwiftUI's.
                let action = item.action.map { "  action=\(NSStringFromSelector($0))" } ?? ""
                lines.append("\(prefix)     \(item.title)\(key)\(item.isEnabled ? "" : "  (disabled)")\(action)")
            }
        }
        return lines
    }

    /// The same dump after the menu bar has been through AppKit's update pass.
    ///
    /// AppKit adds some items only when a menu is about to be shown (N56: the
    /// stock "Enter Full Screen" is one), so a dump of a menu nobody has opened
    /// cannot say whether one would appear beside the app's own. This runs the
    /// update, the tracking notifications and the menus' own will-open calls
    /// without opening anything on the owner's screen.
    @MainActor
    static func menuDumpAfterUpdate() -> [String] {
        guard let main = NSApp.mainMenu else { return [] }
        main.update()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        for item in main.items {
            guard let submenu = item.submenu else { continue }
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.delegate?.menuWillOpen?(submenu)
            submenu.update()
        }
        // A key equivalent nothing claims (⌃⌥⇧⌘J), through the menu bar's
        // own matching — where AppKit would have to add a full-screen item
        // for its shortcut to work before any menu was opened.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
           let probe = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [.control, .option, .shift, .command],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "j", charactersIgnoringModifiers: "j",
                                        isARepeat: false, keyCode: 38) {
            let claimed = main.performKeyEquivalent(with: probe)
            let primary = window.collectionBehavior.contains(.fullScreenPrimary)
            let none = window.collectionBehavior.contains(.fullScreenNone)
            appleTrace("mac menu probe claimed=\(claimed) fullScreenPrimary=\(primary) fullScreenNone=\(none)")
        }
        var lines = menuDump(prefix: "OPENSTREAM-MENU-UPDATED")
        lines.append("OPENSTREAM-MENU-UPDATED toggleFullScreen items: \(main.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }.map(\.title))")
        for item in main.items {
            guard let submenu = item.submenu else { continue }
            submenu.delegate?.menuDidClose?(submenu)
        }
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: main)
        return lines
    }

    private static func printable(_ key: String) -> String {
        switch key.unicodeScalars.first?.value {
        case 0xF700: "up"
        case 0xF701: "down"
        case 0xF702: "left"
        case 0xF703: "right"
        case 0x20: "space"
        default: key
        }
    }

    private static func modifierString(_ mask: NSEvent.ModifierFlags) -> String {
        var out = ""
        if mask.contains(.control) { out += "ctrl-" }
        if mask.contains(.option) { out += "opt-" }
        if mask.contains(.shift) { out += "shift-" }
        if mask.contains(.command) { out += "cmd-" }
        return out
    }

    /// stderr *and* a file beside the PNG.
    ///
    /// The file is what makes the launch mechanism a free choice: `open -g`
    /// starts the app without bringing it to the front — which matters,
    /// because the owner is using this Mac — but hands the caller no pipe to
    /// read stderr from.
    private static func emit(_ lines: [String]) {
        write(lines.joined(separator: "\n") + "\n", to: "shot.log")
    }

    private static func write(_ text: String, to filename: String) {
        FileHandle.standardError.write(Data(text.utf8))
        try? Data(text.utf8).write(
            to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: filename),
            options: .atomic
        )
    }
}
#endif
