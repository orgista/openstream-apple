import SwiftUI

/// The title's correction owns its search and selection tasks for the sheet's lifetime.
struct AppleLibraryFixMatchView: View {
    @Environment(\.dismiss) private var dismiss
    let group: AppleLibrarySeries
    let settings: AppleSettingsStore
    @State private var query = ""
    @State private var year = ""
    @State private var request: UUID?
    @State private var selected: AppleCatalogItem?
    @State private var results: [AppleCatalogItem] = []
    @State private var isSearching = false
    @State private var status: String?
    @State private var library = AppleLocalLibraryStore.shared
    /// Fixed when the sheet opens, so a pick does not retitle it on the way out.
    @State private var title: String

    init(group: AppleLibrarySeries, settings: AppleSettingsStore) {
        self.group = group
        self.settings = settings
        _title = State(initialValue: AppleLocalLibraryStore.shared.metadata[group.id] == nil ? "Match" : "Change Metadata")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name or ID", text: $query)
                    .accessibilityIdentifier("detail.fixMatch.query")
                    .onSubmit(search)
                TextField("Year", text: $year)
                    .accessibilityIdentifier("detail.fixMatch.year")
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching || selected != nil)
                    .accessibilityIdentifier("detail.fixMatch.search")
                if isSearching { ProgressView().accessibilityLabel("Searching") }
                if let status { Text(status).foregroundStyle(.secondary) }
                ForEach(results) { candidate in
                    Button { selected = candidate } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.name)
                            if let date = candidate.releaseInfo { Text(String(date.prefix(4))).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(selected != nil)
                    .accessibilityIdentifier("detail.fixMatch.result.\(candidate.mediaID)")
                }
                #if os(tvOS)
                // tvOS draws no cancellation toolbar item; the remote's Menu
                // button also leaves the sheet.
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("detail.fixMatch.cancel")
                #endif
            }
            .scrollIndicators(.hidden)
            .navigationTitle(title)
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("detail.fixMatch.cancel")
                }
            }
            #endif
            .task(id: request) { await loadResults() }
            .task(id: selected?.id) { await saveSelection() }
        }
        .tint(.primary)
    }

    private func search() {
        guard !isSearching, selected == nil else { return }
        request = UUID()
    }

    private func loadResults() async {
        guard request != nil else { return }
        isSearching = true
        status = nil
        defer { isSearching = false }
        do {
            let values = try await AppleLibraryMetadataResolver.correctionCandidates(
                query: query, year: Int(year), kind: group.parsed.kind,
                tmdbKey: settings.tmdbAPIKey, omdbKey: settings.omdbAPIKey)
            try Task.checkCancellation()
            results = values
            status = values.isEmpty ? "No Results" : nil
        } catch is CancellationError {
        } catch {
            results = []
            status = "Couldn't Search"
        }
    }

    private func saveSelection() async {
        guard let selected else { return }
        do {
            try await library.correctMatch(group, candidate: selected, provider: "manualSearch")
            dismiss()
        } catch {
            self.selected = nil
            status = "Couldn't Save Match"
        }
    }
}
