import SwiftUI

struct AppleLiveChannelPreferencesSection: View {
    let channels: [AppleIPTVChannel]
    let settings: AppleSettingsStore
    @State private var movingID: String?

    private var orderedFavorites: [AppleIPTVChannel] {
        let lookup = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AppleLiveChannelPreferences.order(settings.favoriteLiveChannelOrder, favoriteIDs: settings.favoriteChannelIDs).compactMap { lookup[$0] }
    }

    private var hiddenChannels: [AppleIPTVChannel] {
        channels.filter { settings.hiddenLiveChannelIDs.contains($0.id) }
    }

    /// Each link shows only when its page has rows: an empty page has nothing
    /// to focus, and on Apple TV Menu then left the app (owner 2026-11-04).
    var body: some View {
        Section {
            if !hiddenChannels.isEmpty || !settings.hiddenLiveGroups.isEmpty {
                NavigationLink("Hidden channels") {
                    Form {
                        if !hiddenChannels.isEmpty {
                            Section("Channels") {
                                ForEach(hiddenChannels) { channel in
                                    Button("Restore \(channel.displayName)") { settings.hiddenLiveChannelIDs.remove(channel.id) }
                                }
                            }
                        }
                        if !settings.hiddenLiveGroups.isEmpty {
                            Section("Groups") {
                                ForEach(settings.hiddenLiveGroups.sorted(), id: \.self) { key in
                                    let title = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
                                    Button("Restore \(title)") { settings.hiddenLiveGroups.remove(key) }
                                }
                            }
                        }
                    }
                    .appleSettingsPage("Hidden channels")
                }
            }
            if !orderedFavorites.isEmpty {
                NavigationLink("Reorder favorites") {
                    List {
                        ForEach(orderedFavorites) { channel in
                            #if os(tvOS)
                            Button(channel.displayName) { movingID = movingID == channel.id ? nil : channel.id }
                            if movingID == channel.id {
                                Button("Move Up") { move(channel.id, by: -1) }
                                Button("Move Down") { move(channel.id, by: 1) }
                                Button("Done") { movingID = nil }
                            }
                            #else
                            Text(channel.displayName)
                            #endif
                        }
                        #if !os(tvOS)
                        .onMove { offsets, destination in
                            var order = orderedFavorites.map(\.id)
                            order.move(fromOffsets: offsets, toOffset: destination)
                            settings.favoriteLiveChannelOrder = order
                        }
                        #endif
                    }
                    .appleSettingsPage("Reorder favorites")
                    #if os(iOS)
                    .toolbar { EditButton() }
                    #endif
                }
            }
        }
    }

    private func move(_ id: String, by distance: Int) {
        var order = orderedFavorites.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + distance) else { return }
        order.swapAt(index, index + distance)
        settings.favoriteLiveChannelOrder = order
    }
}
