import SwiftUI

/// A Live failure as one symbol, one short title naming the source or the
/// channel, and one bordered button (`AppleLiveFailureCause`). The same card
/// fills the Live tab, the player frame and the full-screen player; only its
/// size changes.
struct AppleLiveFailureCard: View {
    enum Size { case tab, frame }

    let cause: AppleLiveFailureCause
    var size: Size = .frame
    let action: () -> Void

    var body: some View {
        VStack(spacing: size == .tab ? 16 : 10) {
            Image(systemName: cause.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(cause.title)
                .font(size == .tab ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button(cause.action.title, action: action)
                .buttonStyle(.bordered)
                .controlSize(size == .tab ? .large : .small)
                .tint(.white)
                .accessibilityIdentifier("live.failure.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.failure")
    }
}

/// What a full-screen Live failure needs that the player does not hold: the
/// sources' display names and the way to Settings.
struct AppleLiveFailureContext {
    var sourceNames: [UUID: String] = [:]
    var onOpenSettings: (() -> Void)? = nil
}
