import SwiftUI

/// Inline hosts own their controls; keep cues above their bottom row even
/// while it fades. Native embedded captions remain AVKit's responsibility.
struct AppleLiveInlineCueLayer: View {
    let engine: any ApplePlaybackEngine
    let subtitles: AppleStockPlayerSubtitles
    var onMenuChange: () -> Void = {}

    var body: some View {
        Group {
            if subtitles.drawsInlineCues {
                AppleSubtitleCueLayer(cues: subtitles.cues, videoSize: engine.videoSize,
                                      textBottomLift: 72)
                    .accessibilityIdentifier("player.inline.cueLayer")
            }
        }
        .allowsHitTesting(false)
        .task(id: ObjectIdentifier(engine)) { await subtitles.follow(engine) }
        .onChange(of: subtitles.menuEntries, initial: true) { _, _ in onMenuChange() }
        .onChange(of: subtitles.moreEntries) { _, _ in onMenuChange() }
    }
}
