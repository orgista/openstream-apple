import SwiftUI

/// Settings → Services → Streaming Services.
///
/// The viewer picks the services they subscribe to. Nothing about where else a
/// title can be watched appears anywhere in the app until they do — the feature
/// is off until opted into, which is why this screen exists at all rather than
/// the app guessing from a catalogue.
@MainActor
struct AppleWatchProviderSettingsView: View {
    let settings: AppleSettingsStore
    var embeddedInSplit = false

    @State private var providers: [AppleWatchProvider] = []
    @State private var isLoading = false
    @State private var failure: String?

    private var region: String { AppleWatchProviderResponse.currentRegion() }

    var body: some View {
        content
            .task { if providers.isEmpty { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if providers.isEmpty {
            // Title only, no form column. A settings pane's column is for rows;
            // centring an empty state inside it put "Metadata Is Off" at x=529
            // of a 1920 pt page — dead centre of an invisible 900 pt column
            // starting at the 80 pt inset — so it read as the page having
            // drifted into the left half of the screen (measured 2026-09-17).
            // D4b already settled that a tvOS empty state centres on the whole
            // area rather than on a column.
            Group {
                if isLoading {
                    AppleSourceLoadingState()
                } else if let failure {
                    AppleSourceEmptyState(title: failure, actionTitle: "Try Again", action: reload)
                } else {
                    // Reached when metadata is off or the key is missing, so the
                    // action points at the thing that fixes it.
                    AppleSourceEmptyState(title: "No Services", actionTitle: "Try Again", action: reload)
                }
            }
            .appleSettingsPageTitle("Streaming Services")
        } else {
            list
                .appleSettingsPane("Streaming Services", embedded: embeddedInSplit)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(providers) { provider in
                    Toggle(isOn: binding(for: provider)) {
                        AppleTVNavigationLabel(provider.name)
                    }
                    .accessibilityIdentifier("watchprovider.\(provider.id)")
                }
            } header: {
                Text(region)
            }
        }
        .appleSettingsContent()
    }

    /// Writing straight through to the store: a service is on when its id is
    /// in the set, so there is no second copy of the state to fall out of sync.
    private func binding(for provider: AppleWatchProvider) -> Binding<Bool> {
        Binding(
            get: { settings.watchProviderIDs.contains(provider.id) },
            set: { isOn in
                var ids = settings.watchProviderIDs
                if isOn { ids.insert(provider.id) } else { ids.remove(provider.id) }
                settings.watchProviderIDs = ids
            }
        )
    }

    private func reload() { Task { await load() } }

    private func load() async {
        guard settings.metadataEnabled,
              let configuration = try? AppleTMDBConfiguration(credential: settings.tmdbAPIKey) else {
            failure = "Metadata Is Off"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            providers = try await AppleTMDBClient().availableWatchProviders(
                region: region, configuration: configuration
            )
            failure = nil
        } catch {
            // The message is the failure, not "Error" — the same rule the live
            // failure presentation follows.
            failure = "Could Not Load Services"
        }
    }
}
