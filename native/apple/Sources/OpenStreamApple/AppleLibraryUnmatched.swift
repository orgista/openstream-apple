import SwiftUI

/// Which Library titles belong on the Unmatched shelf: a cached no-match and
/// nothing published since. An outage never caches as a no-match, and a
/// manual or download match publishes metadata, so neither counts.
enum AppleLibraryUnmatchedPolicy {
    static func members(_ groups: [AppleLibrarySeries], metadata: [String: AppleCatalogItem],
                        noMatchIDs: Set<String>) -> [AppleLibrarySeries] {
        groups.filter { noMatchIDs.contains($0.id) && metadata[$0.id] == nil }
            .sorted { $0.parsed.title.localizedStandardCompare($1.parsed.title) == .orderedAscending }
    }
}

/// Each title opens Match; a pick publishes metadata, which takes it off the shelf.
struct AppleLibraryUnmatchedShelf: View {
    let groups: [AppleLibrarySeries]
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    @State private var matching: AppleLibrarySeries?

    var body: some View {
        AppleHomeShelf(title: "Unmatched", headingIdentifier: "library.shelf.Unmatched") {
            ForEach(groups) { group in
                Button { matching = group } label: { AppleLibraryUnmatchedCard(group: group) }
                    .appleCatalogCardButtonStyle()
                    .accessibilityIdentifier("library.unmatched.\(group.parsed.title)")
            }
        } destination: {
            AppleLibraryUnmatchedList(sourceStore: sourceStore, settings: settings)
        }
        .sheet(item: $matching) { group in
            AppleLibraryFixMatchView(group: group, settings: settings)
        }
    }
}

private struct AppleLibraryUnmatchedCard: View {
    let group: AppleLibrarySeries
    private let library = AppleLocalLibraryStore.shared

    var body: some View {
        AppleCatalogCard(item: library.catalogItem(for: group))
            .environment(\.appleLibraryPoster, library.poster(for: group))
    }
}

private struct AppleLibraryUnmatchedList: View {
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    @State private var library = AppleLocalLibraryStore.shared
    @State private var matching: AppleLibrarySeries?

    var body: some View {
        List(library.unmatched) { group in
            Button { matching = group } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.parsed.title).font(.headline)
                    if let file = group.items.first {
                        Text((file.relativePath as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("library.unmatched.row.\(group.parsed.title)")
        }
        .tint(.primary)
        .navigationTitle("Unmatched")
        .scrollIndicators(.never)
        .sheet(item: $matching) { group in
            AppleLibraryFixMatchView(group: group, settings: settings)
        }
    }
}
