#if canImport(UIKit)
import SwiftUI
import UIKit

struct AppleLiveCategoryScrollLock: UIViewRepresentable {
    func makeUIView(context: Context) -> ScrollLockView { ScrollLockView() }
    func updateUIView(_ view: ScrollLockView, context: Context) { view.configure() }

    final class ScrollLockView: UIView {
        #if DEBUG
        private var observation: NSKeyValueObservation?
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if DEBUG
            if window == nil { observation = nil }
            #endif
            configure()
        }

        func configure() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.bouncesVertically = false
                    scroll.alwaysBounceVertical = false
                    scroll.isDirectionalLockEnabled = true
                    #if DEBUG
                    if observation == nil, UserDefaults.standard.bool(forKey: "OpenStreamProbeLiveCategoryScroll") {
                        appleTrace("live category scroll probe ready")
                        observation = scroll.observe(\.contentOffset, options: [.initial, .new]) { _, change in
                            guard let offset = change.newValue?.y else { return }
                            Task { @MainActor in appleTrace("live category vertical offset=\(offset)") }
                        }
                    }
                    #endif
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
