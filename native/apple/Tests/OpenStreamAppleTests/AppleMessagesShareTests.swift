import Foundation
import Testing
@testable import OpenStreamApple

/// The Messages extension cannot be unit tested directly — `Messages.framework`
/// does not exist on macOS, where `swift test` runs — so everything that
/// decides *what* it offers and *what the bubble says* lives in the package
/// and is covered here. The extension itself only maps these onto
/// `MSMessageTemplateLayout`.
@Suite("Messages share")
struct AppleMessagesShareTests {
    private func item(
        _ id: String,
        title: String? = nil,
        artwork: String? = "https://image.tmdb.org/t/p/w500/x.jpg"
    ) -> AppleTopShelfSnapshot.Item {
        .init(
            id: id,
            title: title ?? id,
            kind: "movie",
            artworkURL: artwork.flatMap(URL.init(string:)),
            displayURL: URL(string: "openstream://media/\(id)?action=display")!,
            playURL: nil
        )
    }

    private func snapshot(
        continueWatching: [AppleTopShelfSnapshot.Item] = [],
        topPicks: [AppleTopShelfSnapshot.Item] = []
    ) -> AppleTopShelfSnapshot {
        AppleTopShelfSnapshot(
            version: 1,
            generatedAt: .now,
            continueWatching: continueWatching,
            recentlyAdded: [],
            favorites: [],
            topPicks: topPicks
        )
    }

    /// Continue Watching outranks Top Picks, so the titles someone is actually
    /// part-way through are the ones in reach in a two-row-tall view.
    @Test func continueWatchingComesBeforeTopPicks() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(continueWatching: [item("halfway")], topPicks: [item("popular")])
        )
        #expect(items.map(\.id) == ["halfway", "popular"])
        #expect(items.map(\.origin) == [.continueWatching, .topPick])
    }

    /// A title on both shelves is offered once — and as the thing the sender
    /// is watching, not as a recommendation.
    @Test func aTitleOnBothShelvesIsOfferedOnce() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(continueWatching: [item("dune")], topPicks: [item("dune"), item("other")])
        )
        #expect(items.map(\.id) == ["dune", "other"])
        #expect(items.first?.origin == .continueWatching)
    }

    /// A blank title would render as an empty, tappable row that sends an
    /// empty bubble.
    @Test func blankTitlesAreDropped() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(continueWatching: [item("blank", title: "   "), item("real", title: "Real")])
        )
        #expect(items.map(\.id) == ["real"])
    }

    @Test func titlesAreTrimmed() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(continueWatching: [item("x", title: "  Dune  ")])
        )
        #expect(items.first?.title == "Dune")
    }

    /// The compact presentation is short and the payload is bounded.
    @Test func theListIsCapped() {
        let many = (0..<30).map { item("id-\($0)") }
        let items = AppleMessagesShareCatalog.items(from: snapshot(continueWatching: many))
        #expect(items.count == AppleMessagesShareCatalog.limit)
        #expect(items.first?.id == "id-0")
    }

    /// The cap has to be honoured across the shelf boundary too, not reset
    /// when Top Picks start.
    @Test func theCapSpansBothShelves() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(
                continueWatching: (0..<10).map { item("cw-\($0)") },
                topPicks: (0..<10).map { item("tp-\($0)") }
            )
        )
        #expect(items.count == AppleMessagesShareCatalog.limit)
        #expect(items.map(\.id).suffix(2) == ["tp-0", "tp-1"])
    }

    @Test func noSnapshotOffersNothing() {
        #expect(AppleMessagesShareCatalog.items(from: nil).isEmpty)
        #expect(AppleMessagesShareCatalog.items(from: snapshot()).isEmpty)
    }

    /// Artwork the extension would fetch from its own process is re-checked
    /// against the system-surface policy, not trusted because it was on disk.
    @Test func privateArtworkNeverReachesTheBubble() {
        let items = AppleMessagesShareCatalog.items(
            from: snapshot(continueWatching: [
                item("tokened", artwork: "https://art.fixture/p.jpg?token=abc"),
                item("lan", artwork: "https://192.168.1.95:8090/art.jpg"),
                item("public", artwork: "https://image.tmdb.org/t/p/w500/x.jpg"),
            ])
        )
        #expect(items.first(where: { $0.id == "tokened" })?.artworkURL == nil)
        #expect(items.first(where: { $0.id == "lan" })?.artworkURL == nil)
        #expect(items.first(where: { $0.id == "public" })?.artworkURL != nil)
    }

    // MARK: - The bubble

    @Test func aWatchingTitleSaysSo() {
        let layout = AppleMessagesShareCatalog.layout(
            for: AppleMessagesShareCatalog.items(
                from: snapshot(continueWatching: [item("dune", title: "Dune")])
            )[0]
        )
        #expect(layout.caption == "Dune")
        #expect(layout.subcaption == "Watching now")
        #expect(layout.url == URL(string: "openstream://media/dune?action=display"))
        #expect(layout.imageURL != nil)
    }

    /// A recommendation must not claim the sender is watching it.
    @Test func aTopPickDoesNotClaimToBeInProgress() {
        let layout = AppleMessagesShareCatalog.layout(
            for: AppleMessagesShareCatalog.items(
                from: snapshot(topPicks: [item("popular", title: "Popular")])
            )[0]
        )
        #expect(layout.subcaption == "On oStream")
    }

    /// Out of the app's context the caption alone does not say where the
    /// message came from, and this is the string a notification reads.
    @Test func theSummaryNamesTheApp() {
        let layout = AppleMessagesShareCatalog.layout(
            for: AppleMessagesShareItem(
                id: "x",
                title: "Dune",
                artworkURL: nil,
                displayURL: URL(string: "openstream://media/x?action=display")!,
                origin: .continueWatching
            )
        )
        #expect(layout.summaryText == "Dune on oStream")
    }

    /// The caption is clamped the same way Top Shelf clamps its titles.
    @Test func anAbsurdTitleIsClamped() {
        let layout = AppleMessagesShareCatalog.layout(
            for: AppleMessagesShareItem(
                id: "x",
                title: String(repeating: "A", count: 500),
                artworkURL: nil,
                displayURL: URL(string: "openstream://media/x?action=display")!,
                origin: .topPick
            )
        )
        #expect(layout.caption.count == 200)
    }
}
