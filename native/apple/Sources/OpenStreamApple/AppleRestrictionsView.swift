import SwiftUI

struct AppleRestrictionsView: View {
    let sourceStore: AppleSourceStore
    var embeddedInSplit = false
    private let store = AppleRestrictionStore.shared
    @State private var channels: [AppleIPTVChannel] = []
    @State private var settingPIN = false
    @State private var firstPIN: String?
    @State private var pinError: String?
    @State private var query = ""

    var body: some View {
        Form {
            if !store.hasPIN {
                Button("Set PIN") { firstPIN = nil; pinError = nil; settingPIN = true }
                    .accessibilityIdentifier("restrictions.setPIN")
            } else if !store.sessionUnlocked {
                Button("Unlock Restrictions") {
                    Task { _ = await store.authorize(channelID: "", group: "", title: "Restrictions", settings: true) }
                }
                AppleForgotPINButton()
            } else {
                Section {
                    Button("Change PIN") { firstPIN = nil; pinError = nil; settingPIN = true }
                    Toggle("Lock Settings", isOn: preference(\.lockSettings))
                        .accessibilityIdentifier("restrictions.lockSettings")
                    Toggle("Hide Locked Channels", isOn: preference(\.hideLocked))
                        .accessibilityIdentifier("restrictions.hideLocked")
                }
                Section("Locked Groups") {
                    ForEach(Array(Set(channels.map(\.group).filter { !$0.isEmpty })).sorted(), id: \.self) { group in
                        Toggle(group, isOn: membership(group, path: \.groups))
                            .accessibilityIdentifier("restrictions.group.\(group)")
                    }
                }
                Section("Locked Channels") {
                    TextField("Search Channels", text: $query)
                    ForEach(channels.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { channel in
                        Toggle(channel.name, isOn: membership(channel.id, path: \.channelIDs))
                            .accessibilityIdentifier("restrictions.channel.\(channel.id)")
                    }
                }
                AppleForgotPINButton()
            }
        }
        .scrollIndicators(.hidden)
        .appleSettingsPane("Restrictions", embedded: embeddedInSplit)
        .task(id: sourceStore.sources.filter { $0.kind == .liveTV }.map(\.id)) { await loadChannels() }
        .sheet(isPresented: $settingPIN) {
            ApplePINEntryView(title: firstPIN == nil ? "Set PIN" : "Confirm PIN", error: pinError,
                onSubmit: savePIN, onCancel: { settingPIN = false; firstPIN = nil })
        }
    }
    private func savePIN(_ pin: String) -> Bool {
        guard let firstPIN else { self.firstPIN = pin; return false }
        guard firstPIN == pin else { self.firstPIN = nil; pinError = "PINs did not match."; return false }
        do { try store.setPIN(pin); settingPIN = false; self.firstPIN = nil; return true }
        catch { pinError = "Could not save the PIN."; return false }
    }
    private func preference(_ path: WritableKeyPath<AppleRestrictionPolicy, Bool>) -> Binding<Bool> {
        Binding(get: { store.policy[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }
    private func membership(_ value: String, path: WritableKeyPath<AppleRestrictionPolicy, Set<String>>) -> Binding<Bool> {
        Binding(get: { store.policy[keyPath: path].contains(value) }, set: { included in
            store.update { if included { $0[keyPath: path].insert(value) } else { $0[keyPath: path].remove(value) } }
        })
    }
    private func loadChannels() async {
        var values: [AppleIPTVChannel] = []
        for source in sourceStore.sources where source.kind == .liveTV {
            if let cached = await AppleIPTVChannelCache.shared.snapshot(for: source.id) { values += cached.channels }
        }
        guard !Task.isCancelled else { return }
        channels = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
