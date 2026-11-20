import UIKit
import UniformTypeIdentifiers

/// Saves a shared IMDb or TMDB title link for the app, which opens that
/// title the next time it comes to the front (`AppleAppRouter.consumePendingSharedLink`).
/// The sheet says in one line what happened; any other link gets a Done button.
/// It is offered for web links and plain text (a message or note holding the
/// link); the activation rule can match only types, not hosts, so the host
/// check is `AppleSharedLinkHandoff.deepLink(inShared:)`.
@MainActor
final class ShareViewController: UIViewController {
    private var handoffTask: Task<Void, Never>?
    private var started = false
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.font = .preferredFont(forTextStyle: .headline)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        handoffTask = Task {
            let deepLink = await sharedDeepLink()
            // The sheet was dismissed while the link loaded: save nothing.
            guard !Task.isCancelled else { return }
            guard let deepLink else {
                show("oStream opens IMDb and TMDB title links.")
                navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                })
                installNavigationBar()
                return
            }
            AppleSharedLinkHandoff.save(deepLink)
            show("Open oStream to see this title.")
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        handoffTask?.cancel()
    }

    private func sharedDeepLink() async -> URL? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                let text: String? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                        continuation.resume(returning: (value as? URL)?.absoluteString ?? (value as? String))
                    }
                }
                if let text, let link = AppleSharedLinkHandoff.deepLink(inShared: text) { return link }
            }
        }
        return nil
    }

    private func show(_ text: String) {
        message.text = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func installNavigationBar() {
        let bar = UINavigationBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.items = [navigationItem]
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
