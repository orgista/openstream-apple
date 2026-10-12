#if !os(macOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The channel logo, at whatever size the presentation asks for.
private struct AppleLiveChannelLogo: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        // The shared cached loader, not `AsyncImage`: the picker is opened
        // and closed repeatedly during one sitting, and a channel's logo
        // should not be refetched every time.
        AppleRemoteImage(url: url, contentMode: .fit, placeholderSystemImage: "",
                         loadingFill: .clear)
            .frame(width: side, height: side)
    }
}

/// "LIVE  Evening News" — the same pairing the Apple TV guide's footer card
/// draws, so a channel reads the same on every screen in the app.
private struct AppleLiveChannelNowLine: View {
    let entry: AppleLiveChannelPickerEntry
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 6) {
            if entry.isCurrent {
                Text("LIVE")
                    .font(font.bold())
                    .foregroundStyle(.red)
            }
            if let nowTitle = entry.nowTitle {
                Text(nowTitle)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The leading-edge panel: iPhone, Vision Pro, and the Apple TV's focus list.
struct AppleLiveChannelPickerOverlay: View {
    let channels: [AppleIPTVChannel]
    var guide = AppleIPTVGuide(programmes: [])
    var currentChannelID: String? = nil
    let onSelect: (AppleIPTVChannel) -> Void
    let onDismiss: () -> Void
    /// Leaves full screen without stopping playback, landing back on the Live
    /// tab's guide. `nil` hides the control.
    var onBack: (() -> Void)? = nil

    private var entries: [AppleLiveChannelPickerEntry] {
        AppleLiveChannelPickerEntry.entries(
            channels: channels, guide: guide, currentChannelID: currentChannelID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry.channel)
                        } label: {
                            HStack(spacing: 12) {
                                AppleLiveChannelLogo(url: entry.channel.logoURL, side: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.channel.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if entry.isCurrent || entry.nowTitle != nil {
                                        AppleLiveChannelNowLine(entry: entry)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                            // One element per row. Left as a container, the row
                            // published its logo and its title as two elements
                            // covering the same rectangle; a touch at the row's
                            // centre resolved to the title, not to the row, so
                            // every visible channel read as unhittable and
                            // VoiceOver offered the name with no action
                            // (2026-09-19). `.combine` on the Button is not
                            // enough — the label's children have to go.
                            .accessibilityElement(children: .ignore)
                        }
                        .accessibilityLabel(entry.accessibilityLabel)
                        .accessibilityIdentifier("live.picker.channel.\(entry.channel.id)")
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        Divider()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("live.picker.list")
        }
        // One ground for the whole panel, and only the ground runs under the
        // status bar. The header used to ignore the safe area with everything
        // else, so "Channels" was drawn over the clock on the iPhone
        // (2026-09-20).
        .background(alignment: .center) { panelBackground.ignoresSafeArea() }
    }

    @ViewBuilder
    private var panelBackground: some View {
        #if os(iOS)
        Rectangle().fill(.regularMaterial)
        #else
        Color.black.opacity(0.8)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Channels")
                .font(.headline)
            Spacer()
            if let onBack {
                AppleLiveChannelPickerBackButton(action: onBack)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Close channels")
            .accessibilityIdentifier("live.picker.close")
            .buttonStyle(.plain)
        }
        .padding()
    }
}

/// The iPad strip: logo tiles along the bottom of the video, the channel name
/// and what is on it now under each one. The video is never covered by a panel.
struct AppleLiveChannelStripOverlay: View {
    let channels: [AppleIPTVChannel]
    var guide = AppleIPTVGuide(programmes: [])
    var currentChannelID: String? = nil
    let onSelect: (AppleIPTVChannel) -> Void
    let onDismiss: () -> Void
    var onBack: (() -> Void)? = nil
    var onWatchLive: (() -> Void)? = nil

    private var entries: [AppleLiveChannelPickerEntry] {
        AppleLiveChannelPickerEntry.entries(
            channels: channels, guide: guide, currentChannelID: currentChannelID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Channels")
                        .font(.headline)
                    Spacer()
                    if let onWatchLive {
                        Button("Watch Live", action: onWatchLive)
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Watch Live")
                            .accessibilityIdentifier("live.picker.watchLive")
                    }
                    if let onBack {
                        AppleLiveChannelPickerBackButton(action: onBack)
                    }
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Close channels")
                    .accessibilityIdentifier("live.picker.close")
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // A horizontal ScrollView takes every point of height it is
                // offered. Left to itself it filled the screen and its material
                // covered the video the strip exists to keep visible
                // (2026-09-20).
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(entries) { entry in
                            Button {
                                onSelect(entry.channel)
                            } label: {
                                tile(entry)
                            }
                            .accessibilityLabel(entry.accessibilityLabel)
                            .accessibilityIdentifier("live.picker.channel.\(entry.channel.id)")
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(height: Self.stripHeight)
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("live.picker.list")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }

    private func tile(_ entry: AppleLiveChannelPickerEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AppleLiveChannelLogo(url: entry.channel.logoURL, side: Self.logoSide)
                .frame(width: Self.tileWidth, height: Self.logoSide)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10))
                .overlay {
                    // The channel you are watching is the one marked, and it is
                    // marked with the brand, which is the one accent this app
                    // is allowed.
                    if entry.isCurrent {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(AppleDesignTokens.brandAccent, lineWidth: 2)
                    }
                }
            Text(entry.channel.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if entry.isCurrent || entry.nowTitle != nil {
                AppleLiveChannelNowLine(entry: entry, font: .caption2)
            }
        }
        .frame(width: Self.tileWidth, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
    }

    static let tileWidth: CGFloat = 132
    static let logoSide: CGFloat = 64
    /// The logo tile plus its two lines of type, and nothing more: the strip
    /// only ever occupies this band along the bottom of the video.
    static let stripHeight: CGFloat = 132
}

/// "Guide" — leaves full screen without stopping playback. Distinct from
/// "Close channels", which only puts the picker away and leaves you looking at
/// the video with no obvious way back to the tab you came from.
private struct AppleLiveChannelPickerBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Guide", systemImage: "chevron.backward")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Back to guide")
        .accessibilityIdentifier("live.picker.back")
        .buttonStyle(.plain)
    }
}
#endif
