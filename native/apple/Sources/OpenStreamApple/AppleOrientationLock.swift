/// Small phone windows stay upright outside the player; large windows rotate freely.
enum AppleOrientationPolicy: Equatable {
    case portrait
    case allButUpsideDown
    case all

    static func supportedOrientations(isPhone: Bool, allowsLandscape: Bool, isLargeLayout: Bool = false) -> Self {
        guard isPhone else { return .all }
        return allowsLandscape || isLargeLayout ? .allButUpsideDown : .portrait
    }
}

#if os(iOS)
import Observation
import UIKit

/// Shared by the application delegate and full-screen player lifecycles.
@MainActor
@Observable
public final class AppleOrientationLock {
    public static let shared = AppleOrientationLock()

    public var allowsLandscape = false {
        didSet {
            guard allowsLandscape != oldValue else { return }
            updateOrientation()
        }
    }

    private init() {}

    public func supportedOrientations(for idiom: UIUserInterfaceIdiom, window: UIWindow? = nil) -> UIInterfaceOrientationMask {
        switch AppleOrientationPolicy.supportedOrientations(
            isPhone: idiom == .phone, allowsLandscape: allowsLandscape,
            isLargeLayout: window.map(Self.isLargeLayout) ?? false
        ) {
        case .portrait: .portrait
        case .allButUpsideDown: .allButUpsideDown
        case .all: .all
        }
    }

    public func windowSizeDidChange() {
        updateOrientation()
    }

    private static func isLargeLayout(_ window: UIWindow) -> Bool {
        AppleLayoutClass.isLarge(size: window.bounds.size,
            isRegularWidth: window.traitCollection.horizontalSizeClass == .regular)
    }

    private func updateOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.activationState == .foregroundActive {
            for window in scene.windows where window.isKeyWindow {
                guard let root = window.rootViewController else { continue }
                root.setNeedsUpdateOfSupportedInterfaceOrientations()
                topViewController(from: root).setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Closing a player must not force a large phone window into portrait.
            guard !scene.windows.contains(where: { $0.isKeyWindow && Self.isLargeLayout($0) }) else { continue }
            // Also handles opening a player while the device is already sideways.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: requestedOrientations))
        }
    }

    private var requestedOrientations: UIInterfaceOrientationMask {
        guard allowsLandscape else { return .portrait }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portrait: return .portrait
        default: return .allButUpsideDown
        }
    }

    private func topViewController(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return topViewController(from: selected)
        }
        return controller
    }
}
#endif
