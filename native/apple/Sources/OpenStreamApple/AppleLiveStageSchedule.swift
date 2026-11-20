import SwiftUI

/// The playing channel's programme and what follows it, under the Live stage
/// when a large phone window (an unfolded Duo) sets the stage beside the
/// channel list: the player's column is used down to the tab bar.
struct AppleLiveStageScheduleModel: Equatable {
    /// How far ahead the list reaches.
    static let window: TimeInterval = 12 * 60 * 60

    let now: AppleIPTVProgramme?
    let later: [AppleIPTVProgramme]

    init(guide: AppleIPTVGuide, channelID: String, at time: Date) {
        let programmes = guide.programmes(channelID: channelID,
                                          in: DateInterval(start: time, duration: Self.window))
        now = guide.nowAndNext(channelID: channelID, at: time).now
        later = programmes.filter { $0.start > time }
    }
}

#if os(iOS)
struct AppleLiveStageSchedule: View {
    let channelName: String?
    let channelID: String?
    let guide: AppleIPTVGuide

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: AppleDesignTokens.spacingSmall) {
                    if let channelName {
                        Text(channelName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let channelID {
                        programmes(AppleLiveStageScheduleModel(guide: guide, channelID: channelID, at: context.date))
                    }
                }
                .padding(AppleDesignTokens.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("live.stage.schedule")
    }

    @ViewBuilder
    private func programmes(_ schedule: AppleLiveStageScheduleModel) -> some View {
        if let now = schedule.now {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.title)
                    .font(.title3.weight(.semibold))
                if let subtitle = now.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline)
                }
                // A programme that runs past midnight names its days.
                let days: Date.FormatStyle.DateStyle = Calendar.current.isDate(now.start, inSameDayAs: now.end)
                    ? .omitted : .abbreviated
                Text(now.start.formatted(date: days, time: .shortened)
                     + " – " + now.end.formatted(date: days, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let description = now.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .padding(.top, 4)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if !schedule.later.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: AppleDesignTokens.spacingMedium,
                 verticalSpacing: 0) {
                ForEach(schedule.later) { programme in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(programme.start, format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(programme.title)
                            .lineLimit(2)
                    }
                    .font(.body)
                    .padding(.vertical, AppleDesignTokens.spacingSmall)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, AppleDesignTokens.spacingSmall)
        }
    }
}
#endif
