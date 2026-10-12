#if os(tvOS)
import SwiftUI

/// The same compact channel vocabulary as the player footer, with a lazy
/// vertical list so the entire provider lineup remains reachable.
struct AppleTVMultiviewChannelPicker: View {
    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    let selectedIDs: Set<String>
    let onSelect: (AppleIPTVChannel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(channels.filter { !selectedIDs.contains($0.id) }) { channel in
                Button { onSelect(channel) } label: {
                    HStack(spacing: 24) {
                        AppleRemoteImage(url: channel.logoURL, contentMode: .fit, placeholderSystemImage: "tv")
                            .frame(width: 72, height: 48)
                        VStack(alignment: .leading) {
                            Text(channel.name)
                            if let programme = guide.nowAndNext(channelID: channel.id).now {
                                Text(programme.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("multiview.pick.\(channel.id)")
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Channels")
        }
        .tint(.white)
        .onExitCommand { dismiss() }
    }
}
#endif
