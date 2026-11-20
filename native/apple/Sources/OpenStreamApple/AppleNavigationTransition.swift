#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Whether a push or a presentation is still animating in the app's windows.
///
/// A page that opens straight into its player waits for the push that brought
/// it in: a player presented mid-push left Menu with the stack underneath,
/// which popped the page from under the player and left a black player that
/// nothing could close. iOS and tvOS only; elsewhere nothing waits.
@MainActor
enum AppleNavigationTransition {
    /// Returns once nothing is animating, or after `limit`.
    static func settled(within limit: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + limit
        var waited = false
        while isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            waited = true
            try? await Task.sleep(for: .milliseconds(50))
        }
        if waited { appleTrace("navigation settled before autoplay") }
    }

    private static var isRunning: Bool {
        #if os(iOS) || os(tvOS)
        roots.contains(where: isRunning(in:))
        #else
        false
        #endif
    }

    #if os(iOS) || os(tvOS)
    private static var roots: [UIViewController] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
    }

    private static func isRunning(in controller: UIViewController) -> Bool {
        if controller.transitionCoordinator != nil { return true }
        if let presented = controller.presentedViewController, isRunning(in: presented) { return true }
        return controller.children.contains(where: isRunning(in:))
    }
    #endif
}
