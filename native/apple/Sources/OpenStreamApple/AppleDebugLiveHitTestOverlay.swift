#if DEBUG && os(iOS) && targetEnvironment(simulator)
import SwiftUI
import UIKit

struct AppleDebugLiveHitTestOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let probe = Probe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "live.test.hitProbe"
        probe.accessibilityLabel = "Live hit-test probe"
        view.addSubview(probe)
        let kind = UserDefaults.standard.string(forKey: "OpenStreamLiveHitTestOverlay")
        if kind == "other" || kind == "image" {
            let blocker: UIView = kind == "image" ? UIImageView(image: UIImage(systemName: "rectangle.fill")) : UIView()
            blocker.frame = view.bounds
            blocker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blocker.isUserInteractionEnabled = true
            blocker.isAccessibilityElement = true
            blocker.backgroundColor = .black
            blocker.accessibilityIdentifier = "live.test.blocker"
            blocker.accessibilityLabel = "Live hit-test fixture"
            view.addSubview(blocker)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override var accessibilityValue: String? {
            get {
                guard let window, let control = fullScreenControl(in: window) else { return "waiting for Full Screen" }
                let frame = control.accessibilityFrame
                guard !frame.isEmpty else { return "waiting for Full Screen geometry" }
                let center = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
                let hit = window.hitTest(center, with: nil)
                let clear = hit === control || hit?.isDescendant(of: control) == true
                return "clear=\(clear ? 1 : 0);x=\(frame.minX);y=\(frame.minY);width=\(frame.width);height=\(frame.height)"
            }
            set { super.accessibilityValue = newValue }
        }

        private func fullScreenControl(in view: UIView) -> UIView? {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if view.accessibilityIdentifier == "player.fullscreen" { return view }
            for child in view.subviews {
                if let control = fullScreenControl(in: child) { return control }
            }
            return nil
        }
    }
}
#endif
