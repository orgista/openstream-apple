#if DEBUG && os(macOS)
import AppKit
import QuartzCore

/// Headless measuring aids for the Mac (N34), DEBUG only.
///
/// `-OpenStreamMacWindowOrigin x,y` moves the window's top-left corner to
/// that screen point (from the top-left of the main screen) once it opens —
/// never ordering it forward — so a test copy can sit where the owner's own
/// windows do not cover it. `-OpenStreamMacWindowSize w,h` also sets its
/// size, so every run lays out the same page.
///
/// `-OpenStreamMacFullScreen` / `-OpenStreamMacWindowZoom` (below).
///
/// `-OpenStreamMacFrameMeter start,seconds` counts display frames on the
/// main thread over that window of the launch and logs how many arrived
/// more than 33 ms after the one before (a visible hitch) and the longest
/// gap. The sweep below meters itself.
///
/// `-OpenStreamMacScrollSweep <points>` scrolls the window's main scroll view
/// that far down and back up in 40 pt steps, one per frame, eight seconds
/// after launch — a headless stand-in for a trackpad scroll, so a hitch trace
/// measures real scrolling. It moves the AppKit scroll view directly: moving
/// a SwiftUI `ScrollPosition` instead writes state on the screen being
/// measured and re-renders all of it at every step.
///
/// `-OpenStreamMacScrollTo <points>` moves the same scroll view to that
/// offset once, sixteen seconds after launch (`-OpenStreamMacScrollToAfter`),
/// and leaves it there for a window shot. Discover's `ScrollPosition` review
/// hook does not move the Mac page, so rows below the hero could not be
/// photographed (N54).
///
/// `-OpenStreamMacMenuRefreshAfter <seconds>` runs View ▸ Refresh's own
/// action (`requestRefresh()`) that long after launch and logs whether it was
/// live. A key equivalent posted to a background app never reaches its menu
/// bar, and bringing the test copy forward would take the owner's focus.
@MainActor
enum AppleDebugMacHarness {
    static func startIfRequested() {
        placeWindowIfRequested()
        arrangeWindowIfRequested()
        driveWindowsIfRequested()
        meterIfRequested()
        scrollOnceIfRequested()
        menuRefreshIfRequested()
        let distance = UserDefaults.standard.double(forKey: "OpenStreamMacScrollSweep")
        guard distance > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard let scrollView = mainScrollView() else {
                appleTrace("mac sweep: no scroll view")
                return
            }
            appleTrace("mac sweep start")
            let meter = AppleDebugFrameMeter(view: scrollView)
            let clip = scrollView.contentView
            let bottom = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let target = min(distance, bottom)
            let down = Array(stride(from: 0.0, through: target, by: 40))
            for y in down + down.reversed() {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(16))
            }
            appleTrace("mac sweep end \(Int(target)) pt; \(meter.finish())")
        }
    }

    private static func menuRefreshIfRequested() {
        let after = UserDefaults.standard.double(forKey: "OpenStreamMacMenuRefreshAfter")
        guard after > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            let centre = AppleMacCommandCenter.shared
            appleTrace("mac menu refresh tab=\(centre.selectedTab.map { "\($0)" } ?? "none") live=\(centre.canRefresh)")
            centre.requestRefresh()
        }
    }

    private static func scrollOnceIfRequested() {
        let offset = UserDefaults.standard.double(forKey: "OpenStreamMacScrollTo")
        guard offset > 0 else { return }
        let requested = UserDefaults.standard.double(forKey: "OpenStreamMacScrollToAfter")
        let after = requested > 0 ? requested : 16
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            guard let scrollView = mainScrollView() else {
                appleTrace("mac scroll-to: no scroll view")
                return
            }
            let clip = scrollView.contentView
            let bottom = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(offset, bottom)))
            scrollView.reflectScrolledClipView(clip)
            appleTrace("mac scroll-to \(Int(min(offset, bottom))) of \(Int(bottom)) pt")
        }
    }

    private static func meterIfRequested() {
        let parts = (UserDefaults.standard.string(forKey: "OpenStreamMacFrameMeter") ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(parts[0]))
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.contentView else { return }
            let meter = AppleDebugFrameMeter(view: view)
            try? await Task.sleep(for: .seconds(parts[1]))
            appleTrace("mac frames \(Int(parts[0]))-\(Int(parts[0] + parts[1]))s: \(meter.finish())")
        }
    }

    private static func placeWindowIfRequested() {
        let parts = (UserDefaults.standard.string(forKey: "OpenStreamMacWindowOrigin") ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return }
        Task { @MainActor in
            for _ in 0 ..< 50 {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                   let screen = NSScreen.screens.first {
                    let size = (UserDefaults.standard.string(forKey: "OpenStreamMacWindowSize") ?? "")
                        .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if size.count == 2 {
                        window.setContentSize(NSSize(width: size[0], height: size[1]))
                    }
                    window.setFrameTopLeftPoint(NSPoint(x: parts[0], y: screen.frame.maxY - parts[1]))
                    appleTrace("mac window placed \(Int(window.frame.minX)),\(Int(parts[1])) \(Int(window.frame.width))x\(Int(window.frame.height))")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// `-OpenStreamMacFullScreen <seconds>` enters full screen that long
    /// after launch, and `-OpenStreamMacWindowZoom <seconds>` zooms the
    /// window (the green button's maximise), through the window's own API,
    /// never a keystroke (N44). Logs the screen the window is on.
    private static func arrangeWindowIfRequested() {
        let fullScreen = UserDefaults.standard.double(forKey: "OpenStreamMacFullScreen")
        let zoom = UserDefaults.standard.double(forKey: "OpenStreamMacWindowZoom")
        guard fullScreen > 0 || zoom > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(fullScreen, zoom)))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else {
                appleTrace("mac window arrange: no window")
                return
            }
            if fullScreen > 0, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            if zoom > 0, !window.isZoomed { window.zoom(nil) }
            try? await Task.sleep(for: .seconds(2))
            let screen = window.screen ?? NSScreen.main
            // The full-screen transition needs the window server; with the
            // display asleep it never starts, so the window takes the
            // screen's whole frame instead — the same content size.
            if fullScreen > 0, !window.styleMask.contains(.fullScreen), let screen {
                window.setFrame(screen.frame, display: true)
                appleTrace("mac window full screen unavailable; window set to the screen's frame")
            }
            appleTrace("mac window arranged fullScreen=\(window.styleMask.contains(.fullScreen)) zoomed=\(window.isZoomed) frame=\(NSStringFromRect(window.frame)) screen=\(screen.map { NSStringFromRect($0.frame) } ?? "none") backingScale=\(screen?.backingScaleFactor ?? 0)")
        }
    }

    /// `-OpenStreamMacAssumeVisible YES` (N44): with the display asleep
    /// AppKit stops drawing, so a test copy lays out and draws its windows
    /// itself at 60 Hz and can be measured without waking the display.
    private static func driveWindowsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "OpenStreamMacAssumeVisible") else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The tallest vertically scrolling view in a visible window: Discover's
    /// page, not a horizontal row inside it.
    private static func mainScrollView() -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || scroll.verticalScrollElasticity != .none,
               (scroll.documentView?.frame.height ?? 0) > scroll.frame.height,
               scroll.frame.height > (best?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { visit(content) }
        }
        return best
    }
}

/// Main-thread frame arrival, from the view's display link.
@MainActor
final class AppleDebugFrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var frames = 0
    private var late = 0
    private var longest: CFTimeInterval = 0

    init(view: NSView) {
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if let last {
            let gap = now - last
            longest = max(longest, gap)
            if gap > 0.033 { late += 1 }
        }
        last = now
        frames += 1
    }

    func finish() -> String {
        link?.invalidate()
        link = nil
        return "frames=\(frames) late>33ms=\(late) longest=\(Int((longest * 1000).rounded()))ms"
    }
}
#endif
