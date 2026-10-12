import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var handoffTask: Task<Void, Never>?
    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        handoffTask = Task {
            let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            for item in items {
                for provider in item.attachments ?? [] {
                    for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                        let text: String? = await withCheckedContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                                let text = (value as? URL)?.absoluteString ?? (value as? String)
                                continuation.resume(returning: text)
                            }
                        }
                        guard !Task.isCancelled else { return }
                        guard let text, let url = Self.webURL(in: text), let deepLink = AppleSharedLinkHandoff.deepLink(for: url) else { continue }
                        // Persist before attempting to open: a Share extension has no supported app-opening API.
                        AppleSharedLinkHandoff.save(deepLink)
                        ShareAppOpener.open(deepLink, from: self)
                        try? await Task.sleep(for: .milliseconds(250))
                        extensionContext?.completeRequest(returningItems: nil)
                        return
                    }
                }
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        handoffTask?.cancel()
    }

    private static func webURL(in text: String) -> URL? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: clean), AppleSharedLinkHandoff.deepLink(for: url) != nil { return url }
        guard clean.count <= 8_192, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let urls = detector.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap(\.url)
            .filter { AppleSharedLinkHandoff.deepLink(for: $0) != nil }
        return urls.count == 1 ? urls.first : nil
    }
}
