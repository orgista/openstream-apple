import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// How long a title page takes to fill, one trace line per milestone.
///
/// The push itself was fixed (`9b405f0`), but the page still filled over
/// 10–18 s on the iPhone simulator and nothing said which part was late. Each
/// opening writes `detail fill "<title>" <milestone> +<ms>ms` to the
/// interaction trace, measured from the navigation tap when instrumented
/// (otherwise the page task, explicitly identified in the trace), so a
/// before/after comparison is a grep rather than a stopwatch.
///
/// A reference type on purpose: the page holds it in `@State`, and recording a
/// milestone must not invalidate the view that is being measured.
@MainActor
public final class AppleDetailFillTimeline: NSObject {
    public enum Milestone: String, CaseIterable, Sendable {
        /// The page appeared.
        case paint
        /// First display refresh following the page task; a frame proxy,
        /// not a claim that the compositor presented these pixels.
        case firstFrame
        /// Catalog/local or provider metadata is usable.
        case usableMetadata
        /// A synopsis is on screen — the catalog's own, or the enriched one.
        case overview
        /// The enriched details (overview, cast, genres) arrived.
        case metadata
        /// A series' episode list arrived.
        case episodes
        /// The wordmark finished loading.
        case wordmark
        /// The first hero still has decoded.
        case artworkDecoded
        /// Display-refresh proxy for the first hero still on UIKit platforms.
        case artwork
        /// Critical identity, metadata and episode requests have finished; optional enrichment has its own lifetime.
        case done
    }

    private let now: () -> ContinuousClock.Instant
    private var start: ContinuousClock.Instant?
    private var title = ""
    private var seen: Set<Milestone> = []
    private var active = false
    private static var pendingTap: (title: String, time: ContinuousClock.Instant)?
    private static let log = OSLog(subsystem: "com.orgista.openstream", category: .pointsOfInterest)
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var frameTicks = 0
    private var artworkTicks = 0
    private var artworkPending = false
    #endif

    public static func navigationTap(title: String, at time: ContinuousClock.Instant = .now) {
        pendingTap = (title, time)
        AppleForegroundOpening.hold(for: AppleForegroundOpening.titleHold)
        appleTrace("detail tap \"\(title)\" uptime=\(ProcessInfo.processInfo.systemUptime)")
        os_signpost(.event, log: log, name: "Detail tap")
    }

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
        super.init()
    }

    /// Starts a new opening. Milestones before this are ignored.
    public func begin(title: String) {
        cancelFrameObservation()
        let current = now()
        let origin: String
        if let tap = Self.pendingTap, tap.title == title,
           tap.time.duration(to: current) >= .zero, tap.time.duration(to: current) < .seconds(5) {
            start = tap.time
            origin = "tap"
        } else {
            start = current
            origin = "task"
        }
        Self.pendingTap = nil
        AppleForegroundOpening.hold(for: AppleForegroundOpening.titleHold)
        self.title = title
        seen = []
        active = true
        #if canImport(UIKit)
        frameTicks = 0
        artworkTicks = 0
        artworkPending = false
        #endif
        appleTrace("detail opening \"\(title)\" origin=\(origin)")
    }

    public func observeFirstRefresh() {
        #if canImport(UIKit)
        guard active else { return }
        ensureDisplayLink()
        #endif
    }

    @discardableResult
    public func recordArtworkDecoded() -> String? {
        guard active else { return nil }
        let line = mark(.artworkDecoded)
        #if canImport(UIKit)
        if !seen.contains(.artwork), !artworkPending {
            artworkPending = true
            artworkTicks = 0
            ensureDisplayLink()
        }
        #else
        mark(.artwork, detail: "decoded; no display probe")
        #endif
        return line
    }

    #if canImport(UIKit)
    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    #endif

    public func cancelFrameObservation() {
        active = false
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif
    }

    #if canImport(UIKit)
    @objc private func frame() {
        guard active else { stopDisplayLink(); return }
        if !seen.contains(.firstFrame) {
            frameTicks += 1
            if frameTicks >= 2 { mark(.firstFrame, detail: "display-refresh-proxy") }
        }
        if artworkPending {
            artworkTicks += 1
            if artworkTicks >= 2 {
                mark(.artwork, detail: "display-refresh-proxy")
                artworkPending = false
            }
        }
        if seen.contains(.firstFrame), !artworkPending { stopDisplayLink() }
    }
    #endif

    /// Records the first time a milestone is reached in this opening and
    /// returns the trace line; later calls, and calls before `begin`, return nil.
    @discardableResult
    public func mark(_ milestone: Milestone, detail: String = "") -> String? {
        guard let start, seen.insert(milestone).inserted else { return nil }
        if seen.isSuperset(of: [.firstFrame, .done]) { AppleForegroundOpening.release() }
        let line = Self.line(
            title: title,
            milestone: milestone,
            elapsed: start.duration(to: now()),
            detail: detail
        )
        appleTrace(line)
        os_signpost(.event, log: Self.log, name: "Detail fill", "%{public}@", milestone.rawValue as NSString)
        return line
    }

    public static func line(title: String, milestone: Milestone, elapsed: Duration, detail: String = "") -> String {
        let milliseconds = max(0, Int((Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15).rounded()))
        let suffix = detail.isEmpty ? "" : " \(detail)"
        return "detail fill \"\(title)\" \(milestone.rawValue) +\(milliseconds)ms\(suffix)"
    }
}
