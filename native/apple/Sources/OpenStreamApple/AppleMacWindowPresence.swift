#if os(macOS)
import AppKit
import SwiftUI

/// Reports whether the view it sits in is in a window. A Mac `NavigationStack`
/// takes the covered page out of the window when it pushes another, but
/// SwiftUI sends that page no `onDisappear` and its scroll visibility stays
/// true — so Discover's hero kept cycling and loading trailers under the
/// title page (Mac trace, 2026-09-24). A view never added to a window
/// reports nothing, so callers start from `false`.
///
/// It also reports `false` while the window is off screen or fully covered
/// (`NSWindow.occlusionState`), so a hero in a window nobody can see holds its
/// cycle and trailer (N36).
struct AppleMacWindowPresence: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var reports = AppleWindowPresenceReports()

        /// AppKit calls this in the middle of a SwiftUI update (a push takes
        /// the covered page out of the window), where writing the caller's
        /// state is undefined behaviour. The report waits for the next turn
        /// of the main actor and is dropped if the view has moved again by
        /// then or nothing changed.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeOcclusion()
            deliver()
        }

        /// Removed when the view leaves its window, and in deinit for a view
        /// torn down while still in one (review of 45facac). Only touched on
        /// the main thread; `nonisolated(unsafe)` lets deinit reach it.
        nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        }

        /// In a window, and that window is at least partly on screen.
        private var isShowing: Bool {
            #if DEBUG
            // `-OpenStreamMacAssumeVisible YES`: a test copy measured while
            // the display sleeps counts its window as seen (N44).
            if window != nil, UserDefaults.standard.bool(forKey: "OpenStreamMacAssumeVisible") { return true }
            #endif
            return window?.occlusionState.contains(.visible) ?? false
        }

        private func deliver() {
            let showing = isShowing
            Task { [weak self] in
                guard let self,
                      let report = self.reports.report(showing, stillPresent: self.isShowing) else { return }
                self.onChange(report)
            }
        }

        /// Follows the window the view is in now; none once it has left.
        private func observeOcclusion() {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            guard let window else { return }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.deliver() }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
