import SwiftUI

struct AppleLiveChannelBanner: View {
    let channel: AppleIPTVChannel
    let number: Int?
    let guide: AppleIPTVGuide
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visible {
                Text([number.map(String.init), channel.name].compactMap { $0 }.joined(separator: "  "))
                    .font(.title2.weight(.semibold))
                let programmes = guide.nowAndNext(channelID: channel.id)
                if let now = programmes.now { Text("Now: \(now.title)").font(.callout) }
                if let next = programmes.next { Text("Next: \(next.title)").font(.callout) }
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
