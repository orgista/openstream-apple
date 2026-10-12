import Messages
import OpenStreamApple
import SwiftUI
import UIKit

/// Share what you are watching into a conversation.
///
/// Like the widgets and Top Shelf, this runs in its own process with no access
/// to the app's container, so the list comes entirely from the snapshot the app
/// writes into the shared app group. There is deliberately no account or
/// session logic and no playback here: a Messages extension cannot play video,
/// and anything it fetched would be work done inside Messages' memory budget.
///
/// What is *decided* — which titles are offered, and what the bubble says —
/// lives in `AppleMessagesShareCatalog` in the package, where `swift test`
/// covers it. This file only maps that onto `MSMessageTemplateLayout` and
/// fetches the poster.
final class OpenStreamMessagesViewController: MSMessagesAppViewController {
    private let reader = AppleTopShelfSnapshotReader()
    private var hosting: UIHostingController<OpenStreamMessagesShareList>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = UIHostingController(rootView: makeList(items: [], emptyState: .notPublished))
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        hosting = controller
        reload()
    }

    // MARK: - Conversation handling

    /// Re-read on every activation: the app may have written a new snapshot
    /// since Messages last put this view on screen, and the extension process
    /// outlives a single presentation.
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        reload()
    }

    /// A recipient tapped the bubble. Messages launches this extension rather
    /// than the app, so opening the deep link is what actually gets them to
    /// the title.
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        // Only this app's own routes; a bubble cannot send the recipient anywhere else.
        guard let url = message.url, AppleAppRoute(url: url) != nil else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func reload() {
        let snapshot = reader.read()
        hosting?.rootView = makeList(
            items: AppleMessagesShareCatalog.items(from: snapshot),
            emptyState: .state(hasSnapshot: snapshot != nil)
        )
    }

    private func makeList(
        items: [AppleMessagesShareItem],
        emptyState: AppleWidgetEmptyState
    ) -> OpenStreamMessagesShareList {
        OpenStreamMessagesShareList(items: items, emptyState: emptyState) { [weak self] item in
            self?.insert(item)
        }
    }

    // MARK: - Inserting the bubble

    private func insert(_ item: AppleMessagesShareItem) {
        guard let conversation = activeConversation else { return }
        let layout = AppleMessagesShareCatalog.layout(for: item)
        Task { @MainActor [weak self] in
            let template = MSMessageTemplateLayout()
            template.caption = layout.caption
            template.subcaption = layout.subcaption
            // No `imageTitle`/`imageSubtitle`: those draw text over the
            // artwork, which the app does not do anywhere.
            template.image = await Self.poster(layout.imageURL)

            let message = MSMessage()
            message.layout = template
            message.url = layout.url
            message.summaryText = layout.summaryText

            try? await conversation.insert(message)
            // Collapse back to the conversation so the composed message is
            // visible; in compact there is nothing to collapse.
            if self?.presentationStyle == .expanded { self?.dismiss() }
        }
    }

    /// Posters come from add-on CDNs, so the fetch is bounded: a Messages
    /// extension has a small memory budget and is killed, not warned, when it
    /// runs past it. `AppleSystemArtworkPolicy` has already restricted the URL
    /// to a plain https one with no credentials or query.
    private static func poster(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        let limit = 4_000_000
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.expectedContentLength <= limit else { return nil }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(Int(http.expectedContentLength))
            }
            for try await byte in stream {
                data.append(byte)
                // A server that lied about, or omitted, Content-Length.
                if data.count > limit { return nil }
            }
            return UIImage(data: data)
        } catch {
            // A bubble with a caption and no poster is still a good bubble.
            return nil
        }
    }
}

/// Stock list, stock type, no explainer copy — the same rules the widgets
/// follow. Nothing here is tinted: the brand mark is the only coloured thing
/// in the app, and it only appears in the empty state.
struct OpenStreamMessagesShareList: View {
    let items: [AppleMessagesShareItem]
    let emptyState: AppleWidgetEmptyState
    let onSelect: (AppleMessagesShareItem) -> Void

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                OpenStreamThreeBarMark()
                    .frame(width: 34, height: 24)
                Text(emptyState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("messages.share.empty")
        } else {
            List(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("messages.share.row")
                .accessibilityLabel("\(item.title), \(AppleMessagesShareCatalog.layout(for: item).subcaption)")
                .accessibilityHint("Sends this title to the conversation")
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ item: AppleMessagesShareItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Color.secondary.opacity(0.18)
                if let url = item.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .frame(width: 32, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(AppleMessagesShareCatalog.layout(for: item).subcaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
