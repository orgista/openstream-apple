import SwiftUI

struct AppleLiveChannelPreferencesSection: View {
    let channels: [AppleIPTVChannel]
    let settings: AppleSettingsStore
    @State private var movingID: String?

    private var orderedFavorites: [AppleIPTVChannel] {
        let lookup = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AppleLiveChannelPreferences.order(settings.favoriteLiveChannelOrder, favoriteIDs: settings.favoriteChannelIDs).compactMap { lookup[$0] }
    }

    var body: some View {
        Section {
            NavigationLink("Hidden channels") {
                Form {
                    Section("Channels") {
                        ForEach(channels.filter { settings.hiddenLiveChannelIDs.contains($0.id) }) { channel in
                            Button("Restore \(channel.name)") { settings.hiddenLiveChannelIDs.remove(channel.id) }
                        }
                    }
                    Section("Groups") {
                        ForEach(settings.hiddenLiveGroups.sorted(), id: \.self) { key in
                            let title = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
                            Button("Restore \(title)") { settings.hiddenLiveGroups.remove(key) }
                        }
                    }
                }
                .appleSettingsPage("Hidden channels")
            }
            NavigationLink("Reorder favorites") {
                List {
                    ForEach(orderedFavorites) { channel in
                        #if os(tvOS)
                        Button(channel.name) { movingID = movingID == channel.id ? nil : channel.id }
                        if movingID == channel.id {
                            Button("Move Up") { move(channel.id, by: -1) }
                            Button("Move Down") { move(channel.id, by: 1) }
                            Button("Done") { movingID = nil }
                        }
                        #else
                        Text(channel.name)
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

    private func move(_ id: String, by distance: Int) {
        var order = orderedFavorites.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + distance) else { return }
        order.swapAt(index, index + distance)
        settings.favoriteLiveChannelOrder = order
    }
}
