#if DEBUG && os(tvOS)
import SwiftUI
import UIKit
import os

/// Opt-in, simulator fixture instrumentation. Does not change focus routing.
@MainActor
final class AppleTVGuideLatencyProbe: NSObject {
    static let shared = AppleTVGuideLatencyProbe()
    private static let log = OSLog(subsystem: "com.orgista.openstream", category: .pointsOfInterest)
    private(set) var fixtureDate: Date?
    private var installed = false
    private var launchStart: CFTimeInterval = 0
    private var recordedRows = false
    private var displayLink: CADisplayLink?
    private var sequence = 0
    private var started: CFTimeInterval = 0
    private var focusTime: CFTimeInterval = 0
    private var highlightTime: CFTimeInterval = 0
    private var infoTime: CFTimeInterval = 0
    private var infoWork: CFTimeInterval = 0
    private var direction = ""
    private var signpost = OSSignpostID.invalid

    func install() {
        guard !installed else { return }
        installed = true
        if let raw = UserDefaults.standard.string(forKey: "OpenStreamDebugGuideDate"), let seconds = Double(raw) {
            fixtureDate = Date(timeIntervalSince1970: seconds)
        }
        launchStart = CACurrentMediaTime()
        if let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
           let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.guideTimingSendEvent(_:))) {
            method_exchangeImplementations(original, replacement)
        }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    func rowsReady(count: Int) {
        guard installed, !recordedRows, count > 0 else { return }
        recordedRows = true
        appleTrace(String(format: "timing live.rows %.3fms count=%d", (CACurrentMediaTime() - launchStart) * 1000, count))
    }

    func input(_ event: UIEvent) {
        guard let event = event as? UIPressesEvent,
              let press = event.allPresses.first(where: { $0.phase == .began }),
              [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(press.type) else { return }
        if started > 0 { finish(status: "superseded") }
        sequence += 1
        direction = String(press.type.rawValue)
        started = CACurrentMediaTime()
        focusTime = 0; highlightTime = 0; infoTime = 0; infoWork = 0
        signpost = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "Guide move", signpostID: signpost, "move=%d", sequence)
        displayLink?.isPaused = false
    }

    func focusChanged() {
        guard started > 0 else { return }
        focusTime = CACurrentMediaTime()
        os_signpost(.event, log: Self.log, name: "Guide focus state", signpostID: signpost)
    }

    func highlightChanged() {
        guard started > 0 else { return }
        highlightTime = CACurrentMediaTime()
    }

    func infoResolved(since start: CFTimeInterval) {
        guard started > 0 else { return }
        infoTime = CACurrentMediaTime()
        infoWork += infoTime - start
    }

    @objc private func frame() {
        guard started > 0 else { displayLink?.isPaused = true; return }
        if focusTime > 0, highlightTime > 0, infoTime > 0 { finish(status: "frame") }
        else if CACurrentMediaTime() - started > 1 { finish(status: "no-change") }
    }

    private func finish(status: String) {
        let end = CACurrentMediaTime()
        os_signpost(.end, log: Self.log, name: "Guide move", signpostID: signpost)
        let focusMS = focusTime > 0 ? (focusTime - started) * 1000 : -1
        let highlightMS = highlightTime > 0 ? (highlightTime - started) * 1000 : -1
        let infoMS = infoTime > 0 ? (infoTime - started) * 1000 : -1
        appleTrace(String(format: "guide.latency move=%d direction=%@ focus_state_ms=%.3f highlight_state_ms=%.3f info_ready_ms=%.3f next_frame_ms=%.3f info_work_ms=%.3f status=%@ start_uptime=%.6f end_uptime=%.6f", sequence, direction, focusMS, highlightMS, infoMS, (end-started)*1000, infoWork*1000, status, started, end))
        started = 0
        displayLink?.isPaused = true
    }
}

extension UIApplication {
    @objc fileprivate func guideTimingSendEvent(_ event: UIEvent) {
        AppleTVGuideLatencyProbe.shared.input(event)
        guideTimingSendEvent(event)
    }
}
#endif
