import AVFoundation
import AVKit
import Foundation

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
