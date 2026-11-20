#if os(iOS)
import SwiftUI
import UIKit

/// A cover can be presented by a child navigation controller while the tab
/// controller remains in the accessibility tree. Hide all presenter ancestors
/// for the cover's lifetime, and restore their previous values on dismissal.
struct ApplePlayerAccessibilityModal: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.restore()
    }

    @MainActor final class Controller: UIViewController {
        private struct Presenter {
            weak var view: UIView?
            let wasHidden: Bool
        }
        private var presenters: [Presenter] = []
        private weak var modalView: UIView?
        private var wasModal = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restore()
            var modal: UIViewController = self
            while let parent = modal.parent { modal = parent }
            guard let presenter = modal.presentingViewController else { return }
            modalView = modal.view
            wasModal = modal.view.accessibilityViewIsModal
            modal.view.accessibilityViewIsModal = true
            var ancestor: UIViewController? = presenter
            while let controller = ancestor {
                presenters.append(Presenter(view: controller.view,
                                            wasHidden: controller.view.accessibilityElementsHidden))
                controller.view.accessibilityElementsHidden = true
                ancestor = controller.parent
            }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restore()
        }

        func restore() {
            let hadPresenters = !presenters.isEmpty
            for presenter in presenters { presenter.view?.accessibilityElementsHidden = presenter.wasHidden }
            presenters.removeAll()
            modalView?.accessibilityViewIsModal = wasModal
            modalView = nil
            if hadPresenters { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        }
    }
}
#endif
