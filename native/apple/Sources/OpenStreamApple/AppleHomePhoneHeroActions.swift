import SwiftUI

/// The iPhone hero's buttons, after the Apple TV app: a white rounded-rect
/// "▶ Resume S1, E3" / "▶ Play" and a round grey My List button that turns
/// into a check once the title is saved. Side by side, stacked at the
/// accessibility text sizes so the label wraps instead of clipping.
struct AppleHomePhoneHeroActions: View {
    let button: AppleTitlePagePolicy.HeroButton
    /// Nil hides the My List button: the title has nothing to save it against.
    let isInList: Bool?
    let onPlay: () -> Void
    let onToggleList: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var listButtonSide: CGFloat = 44

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: onPlay) {
                AppleHeroPrimaryButtonLabel(button: button)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 13)
                    .frame(minWidth: 180, minHeight: 50)
                    .foregroundStyle(.black)
                    .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
                    .contentShape(.rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .appleHeroPrimaryButtonState(button)
            .accessibilityIdentifier("home.featured.play")

            if let isInList {
                Button(action: onToggleList) {
                    Label(isInList ? "In My List" : "Add to My List",
                          systemImage: isInList ? "checkmark" : "plus")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: listButtonSide, height: listButtonSide)
                        .background(Color(white: 70.0 / 255.0).opacity(0.9), in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityValue(isInList ? "Saved" : "Not saved")
                .accessibilityIdentifier("home.featured.my-list")
                #if os(iOS)
                // The only caller is the iPhone hero; visionOS 2 lacks this API.
                .sensoryFeedback(.selection, trigger: isInList)
                #endif
            }
        }
    }
}
