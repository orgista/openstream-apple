import SwiftUI

/// The iPhone hero's page dots: the active page is a capsule whose white fill
/// runs left to right with the cycle's timer, the others are dots that shrink
/// towards the far end (`AppleHeroPageDots`). A dot is a button that jumps to
/// its page; VoiceOver gets one adjustable element, "Page 2 of 5".
///
/// The fill is redrawn only when it has grown by half a device pixel
/// (`AppleHeroRotation.Cycle.fillTickInterval`, as on the Mac): ~10 Hz for
/// the 20 pt capsule on a 3x iPhone rather than 30.
///
/// The fill keeps running with Reduce Motion on: it is the only sign that the
/// page is about to change, and it moves in place rather than across the screen.
struct AppleHomePhoneHeroPageIndicator: View {
    let cycle: AppleHeroRotation.Cycle
    let onSelect: (Int) -> Void
    @Environment(\.displayScale) private var displayScale

    /// The strip each dot can be hit in, taller than the dot.
    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: AppleHeroPageDots.spacing) {
            ForEach(0 ..< cycle.count, id: \.self) { position in
                let size = AppleHeroPageDots.size(position: position, index: cycle.index, count: cycle.count)
                Button {
                    onSelect(position)
                } label: {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            if position == cycle.index {
                                TimelineView(.animation(minimumInterval: cycle.fillTickInterval(width: size.width, displayScale: displayScale),
                                                         paused: cycle.isPaused)) { context in
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: size.width * cycle.progress(at: context.date))
                                }
                            }
                        }
                        .clipShape(.capsule)
                        .frame(width: size.width, height: size.height)
                        .frame(height: Self.height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.3), value: cycle.index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured")
        .accessibilityValue("Page \(cycle.index + 1) of \(cycle.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(cycle.index + 1)
            case .decrement: onSelect(cycle.index - 1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("home.featured.pages")
    }
}
