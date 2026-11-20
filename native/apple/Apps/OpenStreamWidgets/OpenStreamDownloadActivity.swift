import ActivityKit
import OpenStreamApple
import SwiftUI
import WidgetKit

/// The download Live Activity: lock screen, and the Dynamic Island in its three
/// presentations.
///
/// Everything shown comes from `AppleDownloadActivityPresentation`, so this and
/// the in-app progress row cannot describe the same download differently.
struct OpenStreamDownloadActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AppleDownloadActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progress(context.state)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle")
                    .accessibilityHidden(true)
            } compactTrailing: {
                // A percentage only where there is a real one to show.
                if let fraction = context.state.fractionComplete {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: "arrow.down.circle")
                    .accessibilityHidden(true)
            }
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<AppleDownloadActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = context.attributes.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(context.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            progress(context.state)
            Text(context.state.byteSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding()
    }

    /// An unknown total draws an indeterminate bar rather than a number the
    /// download cannot support.
    @ViewBuilder
    private func progress(_ state: AppleDownloadActivityState) -> some View {
        if let fraction = state.fractionComplete {
            ProgressView(value: fraction)
                .tint(.white)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.white)
        }
    }
}
