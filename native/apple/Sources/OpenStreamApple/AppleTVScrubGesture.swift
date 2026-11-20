#if os(tvOS)
import SwiftUI
import UIKit

struct AppleTVScrubGesture: UIViewRepresentable {
    let isActive: Bool
    @Binding var input: AppleTVScrubInput
    let onStep: (Double) -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> AppleTVScrubGestureView { AppleTVScrubGestureView() }

    func updateUIView(_ view: AppleTVScrubGestureView, context: Context) {
        view.onBegin = { input.begin() }
        view.onMove = { translation in
            if let seconds = input.move(x: translation.x, y: translation.y) { onStep(seconds) }
        }
        view.onEnd = {
            input.end()
            onEnd()
        }
        view.isActive = isActive
    }

    static func dismantleUIView(_ view: AppleTVScrubGestureView, coordinator: ()) { view.detach() }
}

final class AppleTVScrubGestureView: UIView, UIGestureRecognizerDelegate {
    var onBegin: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            pan.isEnabled = isActive
            if !isActive { onEnd?() }
        }
    }
    private weak var gestureWindow: UIWindow?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.allowedPressTypes = []
        pan.delegate = self
        pan.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        // Indirect touches reach the focused SwiftUI view, not this background.
        window?.addGestureRecognizer(pan)
        gestureWindow = window
    }

    func detach() {
        gestureWindow?.removeGestureRecognizer(pan)
        gestureWindow = nil
        onEnd?()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }

    @objc private func panned() {
        switch pan.state {
        case .began:
            onBegin?()
            onMove?(pan.translation(in: gestureWindow))
        case .changed:
            onMove?(pan.translation(in: gestureWindow))
        case .ended, .cancelled, .failed:
            onEnd?()
        default:
            break
        }
    }
}
#endif
