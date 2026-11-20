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
                        AppleLiveLogoMark(url: channel.logoURL, height: 48, maxWidth: 72,
                            channelName: channel.displayName)
                        VStack(alignment: .leading) {
                            Text(channel.displayName)
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
