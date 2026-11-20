import SwiftUI
#if !os(tvOS)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// The one mark a channel row carries: amber for not playable, red for
/// offline, nothing at all for a working or unchecked channel. The row's own
/// button carries the spoken label, so the dot itself stays out of VoiceOver.
struct AppleChannelHealthDot: View {
    let indicator: AppleChannelHealthIndicator
    var size: CGFloat = 6
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Group {
            // Without colour the two still differ: amber draws as a ring.
            if indicator == .notPlayable, differentiateWithoutColor {
                Circle().strokeBorder(tint, lineWidth: max(1.5, size / 4))
            } else {
                Circle().fill(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch indicator {
        case .notPlayable: AppleDesignTokens.healthAmber
        case .offline: AppleDesignTokens.healthRed
        }
    }
}

/// The (i) detail: when the channel was checked, what the server said, how
/// fast, and which step failed. Reached from a row's long-press menu.
struct AppleChannelHealthDetailView: View {
    let channel: AppleIPTVChannel
    let store: AppleChannelHealthStore
    let guideStore: AppleIPTVGuideStore
    let settings: AppleSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let rows = store.results[AppleChannelHealthResult.storageID(channel.id)]
                .map { AppleChannelHealthDetail(result: $0, now: context.date).rows } ?? []
            #if os(tvOS)
            tvBody(rows: rows)
            #else
            NavigationStack {
                Form {
                    Section {
                        ForEach(rows) { LabeledContent($0.label, value: $0.value) }
                    }
                    AppleGuideChannelAssignmentPicker(channel: channel, guideStore: guideStore, settings: settings)
                    AppleFormActionSection {
                        Button(store.isSweeping ? "Checking" : "Check Again") { store.recheck(channel) }
                            .accessibilityIdentifier("health.detail.recheck")
                    }
                }
                .navigationTitle(channel.displayName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            #endif
        }
        .accessibilityIdentifier("health.detail")
    }

    #if os(tvOS)
    /// Plain rows and the settings row style rather than a `Form`: in a tvOS
    /// sheet the system focus glass drew over the button's own title, and a
    /// sheet sizes to content a `Form` does not report. The button is gated
    /// in the store, never `.disabled`, so it stays the sheet's focus target.
    private func tvBody(rows: [AppleChannelHealthDetail.Row]) -> some View {
        let metrics = AppleTVSettingsMetrics.standard
        return VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            TVPageHeader(title: channel.displayName)
            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                    Spacer(minLength: 24)
                    Text(row.value).foregroundStyle(AppleDesignTokens.textSecondary)
                }
                .padding(.horizontal, metrics.rowHorizontalPadding)
                .frame(height: metrics.rowHeight)
                .background(AppleDesignTokens.surface, in: RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            AppleGuideChannelAssignmentPicker(channel: channel, guideStore: guideStore, settings: settings)
            Button { store.recheck(channel) } label: {
                Text(store.isSweeping ? "Checking" : "Check Again")
                    .padding(.horizontal, metrics.rowHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, alignment: .leading)
            }
            .buttonStyle(AppleTVSettingsRowStyle(isSelected: false, cornerRadius: metrics.rowCornerRadius))
            .accessibilityIdentifier("health.detail.recheck")
            .padding(.top, metrics.rowSpacing)
        }
        .frame(width: 820, alignment: .leading)
        .padding(.horizontal, 48)
        .padding(.bottom, 48)
    }
    #endif
}

/// Settings → Live TV: the summary line and the sweep.
struct AppleChannelHealthSettingsRows: View {
    let store: AppleChannelHealthStore
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    #if os(tvOS)
    let webManagement: any AppleWebManagementServing
    #endif
    /// Set when Check Channels Now found nothing to check; shown in place of
    /// the summary until the lineup has channels.
    @State private var nothingToCheck: String?

    var body: some View {
        #if os(macOS)
        // One row, System Settings style: the summary on the left, its two
        // actions as content-sized buttons at the trailing edge.
        HStack(spacing: 12) {
            summaryLine
            AppleFormActionBar {
                sweepButton
            }
        }
        if let progress = store.progress {
            progressBar(progress)
        }
        #elseif os(tvOS)
        // One row: a summary line on its own could not take focus (owner 2026-11-04).
        sweepButton
        #else
        summaryLine
        if let progress = store.progress {
            progressBar(progress)
        }
        sweepButton
        #endif
    }

    private var summaryLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                #if !os(tvOS)
                Text("Channel Health")
                #endif
                Text(summary(now: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.health.summary")
        }
        .onChange(of: store.lineup.isEmpty) { _, isEmpty in
            if !isEmpty { nothingToCheck = nil }
        }
        .task {
            await store.loadIfNeeded()
            #if !os(tvOS)
            await store.prepareLineupIfNeeded(settings: settings, sourceStore: sourceStore, allowsNetwork: false)
            #endif
        }
    }

    private func progressBar(_ progress: AppleChannelHealthStore.Progress) -> some View {
        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
            .accessibilityLabel("Checking channels")
            .accessibilityValue(AppleChannelHealthSummary.progress(completed: progress.completed, total: progress.total))
    }

    @ViewBuilder
    private var sweepButton: some View {
        if store.progress != nil {
            Button { store.cancelSweep() } label: { sweepLabel("Stop Checking") }
                .accessibilityIdentifier("settings.health.stop")
        } else {
            Button {
                Task {
                    guard !store.isPreparingLineup else { return }
                    await store.prepareLineupIfNeeded(settings: settings, sourceStore: sourceStore, allowsNetwork: true)
                    guard !Task.isCancelled else { return }
                    if store.lineup.isEmpty {
                        let failure = sourceStore.sources.first {
                            $0.kind == .liveTV && $0.isEnabled && $0.hasCurrentValidationFailure
                        }?.validationFailureSummary
                        nothingToCheck = AppleChannelHealthSummary.nothingToCheck(sourceFailure: failure)
                    } else {
                        nothingToCheck = nil
                        store.startSweep()
                    }
                }
            } label: {
                sweepLabel("Check Channels Now")
            }
                .disabled(store.hasLivePlayback)
                .accessibilityIdentifier("settings.health.check")
        }
    }

    @ViewBuilder
    private func sweepLabel(_ title: String) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            summaryLine
            if let progress = store.progress {
                progressBar(progress)
            }
        }
        #else
        Text(title)
        #endif
    }

    private func summary(now: Date) -> String {
        if let progress = store.progress {
            return AppleChannelHealthSummary.progress(completed: progress.completed, total: progress.total)
        }
        if let nothingToCheck, store.lineup.isEmpty { return nothingToCheck }
        return store.summary(now: now)
    }
}
