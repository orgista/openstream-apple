import SwiftUI

struct AppleLiveChannelBanner: View {
    let channel: AppleIPTVChannel
    let number: Int?
    /// Now and Next come from here; without it the banner names the channel only.
    let guide: AppleIPTVGuide?
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visible {
                HStack(spacing: 12) {
                    AppleLiveLogoMark(url: channel.logoURL, height: 36, maxWidth: 64,
                        channelName: channel.displayName, fallbackText: "", alignment: .leading)
                    Text([number.map(String.init), channel.displayName].compactMap { $0 }.joined(separator: "  "))
                        #if os(tvOS)
                        .font(.title2.weight(.semibold))
                        #else
                        .font(.headline)
                        #endif
                }
                if let programmes = guide?.nowAndNext(channelID: channel.id) {
                    if let now = programmes.now { Text("Now: \(now.title)").font(.callout) }
                    if let next = programmes.next { Text("Next: \(next.title)").font(.callout) }
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 3, y: 1)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.player.channelBanner")
        .task(id: channel.id) {
            visible = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            visible = false
        }
    }
}

/// The channel swipes have reached while they wait to tune, as on the tvOS
/// banner: logo, number and name.
struct AppleLiveZapPendingBanner: View {
    let zapper: AppleLiveZapCoalescer
    let channels: [AppleIPTVChannel]

    var body: some View {
        if let id = zapper.pendingID, let channel = channels.first(where: { $0.id == id }) {
            AppleLiveChannelBanner(channel: channel, number: channel.channelNumber, guide: nil)
        }
    }
}
