import AVFoundation
import AVKit
import Foundation

#if os(iOS)
import SwiftUI

final class ApplePlayerPictureInPictureView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct ApplePlayerPictureInPictureLayer: UIViewRepresentable {
    let view: ApplePlayerPictureInPictureView

    func makeUIView(context: Context) -> ApplePlayerPictureInPictureView { view }
    func updateUIView(_ uiView: ApplePlayerPictureInPictureView, context: Context) {}
}
#endif

#if os(visionOS)
/// visionOS 2 through 25 receives the standard AVKit player. visionOS 26 adds
/// an opt-in immersive experience without changing the baseline controller.
/// These hooks stay on `ApplePlayerHost` so the view does not need to reach
/// through to the controller's experience controller directly.
@available(visionOS 2.0, *)
extension ApplePlayerHost {
    public var supportsImmersiveExperience: Bool {
        if #available(visionOS 26.0, *) {
            viewController.experienceController.availableExperiences.contains(.immersive)
        } else {
            false
        }
    }

    /// Adds AVKit's immersive experience for a VR video (the window and
    /// expanded views stay as they are for everything else).
    @available(visionOS 26.0, *)
    func allowImmersive() {
        viewController.experienceController.allowedExperiences = .only([.embedded, .expanded, .immersive])
    }

    @available(visionOS 26.0, *)
    @discardableResult
    public func enterImmersive() async -> Bool {
        let controller = viewController.experienceController
        guard controller.availableExperiences.contains(.immersive) else { return false }
        return await controller.transition(to: .immersive) == .completed
    }

    @available(visionOS 26.0, *)
    public func leaveImmersive() async {
        _ = await viewController.experienceController.transition(to: .expanded)
    }
}
#endif
