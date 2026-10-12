#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct AppleCopiedLinkButton: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 10) {
            Text("Open Copied Link").accessibilityHidden(true)
            // PasteButton's native title cannot be renamed; keep its stock icon
            // and name the action beside it and in its accessibility label.
            // URL as well as text: Safari's Copy puts a URL item on the
            // pasteboard, and a text-only button stayed greyed out for it on
            // an iPhone (DevPlus, 2026-10-06).
            PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                guard let provider = providers.first else { return }
                Self.loadText(from: provider) { value in
                    Task { @MainActor in query = value }
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open Copied Link")
            .accessibilityIdentifier("search.openCopiedLink")
        }
        .padding()
    }

    /// The link as text, from a URL item or a plain-text one. Item providers
    /// call back off the main actor; only the text crosses back.
    nonisolated private static func loadText(from provider: NSItemProvider,
                                             then deliver: @escaping @Sendable (String) -> Void) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { deliver(url.absoluteString) }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                if let text { deliver(text) }
            }
        }
    }
}
#endif
