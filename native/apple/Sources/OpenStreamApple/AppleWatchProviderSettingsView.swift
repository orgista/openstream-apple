import SwiftUI

/// Settings → Services → Streaming Services.
///
/// The viewer adds the services they subscribe to from the region's most
/// popular ten. Nothing about where else a
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

    /// What `load()` needs before it can reach the network. Nil covers both the
    /// switch being off and the key being absent, which is the same dead end.
    private var configuration: AppleTMDBConfiguration? {
        guard settings.metadataEnabled else { return nil }
        return try? AppleTMDBConfiguration(credential: settings.tmdbAPIKey)
    }

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
                } else if configuration == nil {
                    // `load()` returns before it reaches the network when
                    // metadata is off or the key is missing, so Try Again ran,
                    // changed nothing and left the same screen — an
                    // unresponsive button by every measure (button crawl,
                    // 2026-09-19). The way out of this one is
                    // Settings → Metadata, not a retry.
                    AppleSourceEmptyState(title: "Metadata Is Off")
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

    private var added: [AppleWatchProvider] {
        AppleWatchProviderPolicy.added(providers, enabledProviderIDs: settings.watchProviderIDs)
    }

    private var addable: [AppleWatchProvider] {
        AppleWatchProviderPolicy.addable(providers, enabledProviderIDs: settings.watchProviderIDs)
    }

    private var list: some View {
        Form {
            Section {
                ForEach(added) { provider in
                    row(provider)
                }
                #if os(iOS) || os(visionOS)
                .onDelete { offsets in
                    let services = added
                    for index in offsets { remove(services[index]) }
                }
                #endif
                if !addable.isEmpty {
                    addControl
                }
            } header: {
                Text(region)
            }
        }
        .appleSettingsContent()
    }

    @ViewBuilder
    private func row(_ provider: AppleWatchProvider) -> some View {
        #if os(tvOS)
        // A pushed page, not a confirmationDialog: the dialog drew its focused
        // choice white on the white focus fill (N71).
        NavigationLink {
            AppleTVWatchProviderRemovePage(provider: provider) { remove(provider) }
        } label: {
            AppleTVNavigationLabel(provider.name)
        }
        .accessibilityIdentifier("watchprovider.\(provider.id)")
        #else
        Text(provider.name)
            .accessibilityIdentifier("watchprovider.\(provider.id)")
            .contextMenu {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(provider) }
            }
        #endif
    }

    @ViewBuilder
    private var addControl: some View {
        #if os(tvOS)
        // Menus are awkward with the remote, so the Apple TV pushes the list.
        NavigationLink {
            AppleTVWatchProviderAddPage(providers: addable) { add($0) }
        } label: {
            AppleTVNavigationLabel("Add Service")
        }
        .accessibilityIdentifier("watchprovider.add")
        #else
        Menu {
            ForEach(addable) { provider in
                Button(provider.name) { add(provider) }
                    .accessibilityIdentifier("settings.watchProviders.add.\(provider.id)")
            }
        } label: {
            // The whole row opens the menu, not just the words (iPhone 27 v2
            // re-run).
            Label("Add Service", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("watchprovider.add")
        #endif
    }

    /// Writing straight through to the store: a service is added when its id
    /// is in the set, so there is no second copy of the state to fall out of sync.
    private func add(_ provider: AppleWatchProvider) {
        settings.watchProviderIDs.insert(provider.id)
    }

    private func remove(_ provider: AppleWatchProvider) {
        settings.watchProviderIDs.remove(provider.id)
    }

    private func reload() { Task { await load() } }

    private func load() async {
        guard let configuration else {
            failure = "Metadata Is Off"
            return
        }
        isLoading = true
        let started = ContinuousClock.now
        // The old failure comes off the screen while the new attempt runs.
        // Leaving it up meant pressing Try Again changed nothing on screen at
        // all, and on a fast failure the button read as dead (button crawl,
        // 2026-09-19).
        failure = nil
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
        // On a machine with no network the request comes back inside a frame,
        // and the loading state was up for less time than it takes to draw:
        // Try Again answered a press with the screen it was pressed on
        // (button crawl, 2026-09-19).
        try? await Task.sleep(for: AppleProgressVisibility.remaining(since: started))
    }
}

#if os(tvOS)
/// The Apple TV's Add Service list: the same top ten the other platforms'
/// menu offers. Choosing one adds it and returns to the list.
@MainActor
private struct AppleTVWatchProviderAddPage: View {
    let providers: [AppleWatchProvider]
    let onAdd: (AppleWatchProvider) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(providers) { provider in
                    Button {
                        onAdd(provider)
                        dismiss()
                    } label: {
                        // Readable on the white focus fill (N71).
                        AppleTVFocusReadableText(provider.name)
                    }
                    .accessibilityIdentifier("settings.watchProviders.add.\(provider.id)")
                }
            }
        }
        .appleSettingsPage("Add Service")
    }
}

/// One added service on the Apple TV, with the way to remove it.
@MainActor
private struct AppleTVWatchProviderRemovePage: View {
    let provider: AppleWatchProvider
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    AppleTVFocusReadableText("Remove", isDestructive: true)
                }
                .accessibilityIdentifier("watchprovider.remove.\(provider.id)")
            }
        }
        .appleSettingsPage(provider.name)
    }
}
#endif
