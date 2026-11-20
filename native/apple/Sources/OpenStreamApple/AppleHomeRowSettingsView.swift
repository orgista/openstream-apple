import SwiftUI

struct AppleHomeRowSettingsView: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    var embeddedInSplit = false
    @State private var confirmsReset = false

    private var shelves: [AppleMediaServerLibraryStore.Shelf] {
        let sourceIDs = Set(sourceStore.sources.map(\.id))
        return mediaServerLibrary.shelves.filter { sourceIDs.contains($0.sourceID) }
    }

    private var rows: [AppleHomeRowSetting] {
        let knownSources = sourceStore.sources.map { source in
            var source = source
            source.isEnabled = true
            return source
        }
        let serverRows = AppleDiscoverServerRows.rows(shelves, sources: knownSources,
            pendingShelfIDs: Set(shelves.map(\.id)))
        return AppleHomeRowSetting.rows(serverRows: serverRows)
    }

    var body: some View {
        List {
            Section("Rows") {
                ForEach(rows) { row in rowLink(row) }
            }
            let services = AppleHomeRowSetting.services(shelves: shelves)
            if !services.isEmpty {
                Section("Services") {
                    ForEach(services) { service in rowLink(service) }
                }
            }
            Section {
                Button("Reset All", role: .destructive) { confirmsReset = true }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings.homeRows.resetAll")
                    .confirmationDialog("Reset All?", isPresented: $confirmsReset, titleVisibility: .visible) {
                        Button("Reset All", role: .destructive) { AppleHomeRowSetting.resetAll(in: settings) }
                        Button("Cancel", role: .cancel) { }
                    }
            }
        }
        .scrollIndicators(.never)
        .appleSettingsPane("Home Rows", embedded: embeddedInSplit)
        .navigationDestination(for: AppleHomeRowSetting.self) { row in
            AppleHomeRowEditor(row: row, settings: settings)
        }
    }

    private func rowLink(_ row: AppleHomeRowSetting) -> some View {
        NavigationLink(value: row) {
            LabeledContent(row.title(in: settings), value: row.isShown(in: settings) ? "On" : "Off")
        }
        .accessibilityIdentifier("settings.homeRows.\(row.id)")
    }
}

private struct AppleHomeRowEditor: View {
    let row: AppleHomeRowSetting
    let settings: AppleSettingsStore
    @State private var isShown: Bool
    @State private var name: String

    init(row: AppleHomeRowSetting, settings: AppleSettingsStore) {
        self.row = row
        self.settings = settings
        _isShown = State(initialValue: row.isShown(in: settings))
        _name = State(initialValue: row.title(in: settings))
    }

    var body: some View {
        Form {
            Toggle("Show on Home", isOn: $isShown)
                .accessibilityIdentifier("settings.homeRows.show")
                .onChange(of: isShown) { _, shown in row.setShown(shown, in: settings) }
            TextField("Name", text: $name, prompt: Text(row.defaultName))
                .accessibilityIdentifier("settings.homeRows.name")
                .onSubmit { row.setName(name, in: settings) }
            if row.customName(name) != nil {
                Button("Reset Name") {
                    row.setName("", in: settings)
                    name = row.defaultName
                }
                .accessibilityIdentifier("settings.homeRows.resetName")
            }
        }
        .appleSettingsPage(row.title(in: settings))
        .onDisappear { row.setName(name, in: settings) }
        .onChange(of: row.isShown(in: settings)) { _, shown in isShown = shown }
        .onChange(of: settings.homeRowNames[row.id]) { _, value in
            if value != row.customName(name) { name = row.title(in: settings) }
        }
    }
}
