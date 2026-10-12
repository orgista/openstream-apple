#if DEBUG
import Foundation
#if os(macOS)
import AppKit
#endif

/// Review builds only: how long the main thread is busy after a title page is
/// pushed (N47), measured in the app rather than by attaching a profiler.
///
/// `-OpenStreamTitlePageProbe YES` with the `OpenStreamVisionScreen` hook:
/// each push prints `[OpenStream] title-open <label> busy <ms>/600 ms …`.
/// Busy is the time the main run loop spends outside its wait — the same
/// thing a profiler's main-thread samples count — over the 600 ms after the
/// push (N45's window) and over 2 s, the longest busy streak (gaps ≤ 2 ms
/// merged), when the page first appeared, and the busy spans themselves.
/// With `-OpenStreamMainThreadSamples` the push is also sampled
/// (`AppleMainThreadSampler`). On the Mac each push also prints the window
/// toolbar's items added and removed in those 2 s, and the items after it
/// (`title-open <label> toolbar …`), to show what a push rebuilds (N50).
@MainActor
enum AppleTitlePageOpenProbe {
    static let isEnabled = UserDefaults.standard.bool(forKey: "OpenStreamTitlePageProbe")

    private static var observer: CFRunLoopObserver?
    private static var busySince: CFAbsoluteTime?
    private static var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
    private static var windowStart: CFAbsoluteTime?
    private static var firstAppear: CFAbsoluteTime?
    #if os(macOS)
    private static var toolbarEvents: [String] = []
    private static var toolbarObservers: [NSObjectProtocol] = []
    #endif

    /// Call where the push is requested.
    static func pushed(_ label: String) {
        guard isEnabled else { return }
        install()
        #if (os(macOS) || targetEnvironment(simulator)) && arch(arm64)
        AppleMainThreadSampler.captureMainThread()
        AppleMainThreadSampler.sample(label: label)
        #endif
        let now = CFAbsoluteTimeGetCurrent()
        windowStart = now
        busySince = now
        intervals = []
        firstAppear = nil
        #if os(macOS)
        // What the pop back before this push did.
        if !toolbarEvents.isEmpty { toolbarReport("\(label) (before, since the last report)") }
        toolbarEvents = []
        #endif
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2100))
            report(label, start: now)
        }
    }

    /// The page's first `onAppear` after the push.
    static func appeared() {
        guard isEnabled, windowStart != nil, firstAppear == nil else { return }
        firstAppear = CFAbsoluteTimeGetCurrent()
    }

    private static func install() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated { AppleTitlePageOpenProbe.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        #if os(macOS)
        for (name, sign) in [(NSToolbar.willAddItemNotification, "+"), (NSToolbar.didRemoveItemNotification, "-")] {
            toolbarObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // A main-actor class, so it may cross into the closure below.
                let item = note.userInfo?["item"] as? NSToolbarItem
                MainActor.assumeIsolated { toolbarEvents.append(sign + (item.map(describe) ?? "?")) }
            })
        }
        #endif
    }

    #if os(macOS)
    private static func describe(_ item: NSToolbarItem) -> String {
        let id = item.itemIdentifier.rawValue
        let short = id.count > 24 ? String(id.suffix(24)) : id
        return "\(short)@\(String(UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xFFFFF, radix: 16))"
    }

    private static func toolbarReport(_ label: String) {
        let items = NSApp.windows.compactMap(\.toolbar).first?.items.map(describe) ?? []
        let adds = toolbarEvents.filter { $0.hasPrefix("+") }.count
        print("[OpenStream] title-open \(label) toolbar +\(adds) -\(toolbarEvents.count - adds) [\(toolbarEvents.joined(separator: " "))] now [\(items.joined(separator: " "))]")
    }
    #endif

    private static func runLoop(_ activity: CFRunLoopActivity) {
        guard windowStart != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting {
            busySince = now
        } else if let since = busySince {
            intervals.append((since, now))
            busySince = nil
        }
    }

    private static func busy(from start: CFAbsoluteTime, to end: CFAbsoluteTime,
                             in spans: [(start: CFAbsoluteTime, end: CFAbsoluteTime)]) -> (total: Double, longest: Double) {
        var total = 0.0
        var longest = 0.0
        var streak: (start: CFAbsoluteTime, end: CFAbsoluteTime)?
        for span in spans {
            let s = max(span.start, start), e = min(span.end, end)
            guard e > s else { continue }
            total += e - s
            if let current = streak, s - current.end <= 0.002 {
                streak = (current.start, e)
            } else {
                streak = (s, e)
            }
            if let current = streak { longest = max(longest, current.end - current.start) }
        }
        return (total * 1000, longest * 1000)
    }

    private static func report(_ label: String, start: CFAbsoluteTime) {
        guard windowStart == start else { return }
        var spans = intervals
        if let since = busySince { spans.append((since, CFAbsoluteTimeGetCurrent())) }
        let short = busy(from: start, to: start + 0.6, in: spans)
        let long = busy(from: start, to: start + 2.0, in: spans)
        let appear = firstAppear.map { String(Int((($0 - start) * 1000).rounded())) } ?? "-"
        let loops = spans.filter { $0.end - $0.start > 0.002 && $0.start < start + 0.6 }
            .map { "\(Int((($0.start - start) * 1000).rounded()))-\(Int((($0.end - start) * 1000).rounded()))" }
        print("[OpenStream] title-open \(label) loops [\(loops.joined(separator: " "))]")
        print("[OpenStream] title-open \(label) busy \(Int(short.total.rounded()))/600 ms longest \(Int(short.longest.rounded())) ms; busy \(Int(long.total.rounded()))/2000 ms; appear +\(appear) ms)")
        #if os(macOS)
        toolbarReport(label)
        #endif
        fflush(stdout)
        windowStart = nil
        intervals = []
    }
}
#endif
