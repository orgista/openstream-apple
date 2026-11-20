import SwiftUI

struct AppleGuideChannelAssignmentPicker: View {
    let channel: AppleIPTVChannel
    let guideStore: AppleIPTVGuideStore
    let settings: AppleSettingsStore
    @State private var selection = ""

    var body: some View {
        let names = guideStore.channelNames[channel.sourceID.uuidString] ?? [:]
        if !names.isEmpty {
            Group {
            #if os(tvOS)
            AppleTVChoicePicker("Guide data", selection: $selection,
                options: [.init(value: "", title: "Automatic")] + names.keys.sorted().map { id in
                    .init(value: id, title: names[id] ?? id)
                })
            #else
            Picker("Guide data", selection: $selection) {
                Text("Automatic").tag("")
                ForEach(names.keys.sorted(), id: \.self) { id in
                    Text(names[id] ?? id).tag(id)
                }
            }
            #endif
            }
            .accessibilityIdentifier("channel.guideData")
            .onAppear { selection = settings.guideChannelAssignments[channel.id] ?? "" }
            .onChange(of: selection) { _, value in
                if value.isEmpty { settings.guideChannelAssignments.removeValue(forKey: channel.id) }
                else { settings.guideChannelAssignments[channel.id] = value }
            }
        }
    }
}
