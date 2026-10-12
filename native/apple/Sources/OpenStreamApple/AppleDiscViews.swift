import SwiftUI

/// The poster corner badge for a disc image: `opticaldisc.fill` in a small
/// dark circle, where the other poster badges sit (top leading).
struct AppleDiscBadge: View {
    #if os(tvOS)
    private let diameter: CGFloat = 40
    private let glyph: CGFloat = 20
    #else
    private let diameter: CGFloat = 24
    private let glyph: CGFloat = 12
    #endif

    var body: some View {
        Image(systemName: "opticaldisc.fill")
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(.black.opacity(0.7), in: .circle)
            .padding(8)
            .accessibilityHidden(true)
    }
}

/// The disc turning, in place of the spinner while a disc item opens. Reduce
/// Motion keeps it still. `symbolEffect(.rotate)` exists on every OS this app
/// supports (iOS/tvOS 18, macOS 15, visionOS 2).
struct AppleDiscSpinner: View {
    var tint: Color = .white
    var size: CGFloat = 17
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "opticaldisc.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
            .accessibilityLabel("Opening disc")
    }
}

/// The disc's titles (the feature, extras), longest first. Choosing one plays
/// that title.
struct AppleDiscTitlesRow: View {
    let titles: [AppleDiscTitle]
    var horizontalInset: CGFloat = 16
    let play: (AppleDiscTitle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppleTitlePageSectionTitle("Titles")
                .padding(.horizontal, horizontalInset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(titles) { title in
                        Button { play(title) } label: { card(title) }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityLabel("\(title.name), \(title.durationLabel)")
                            .accessibilityIdentifier("detail.disc.title.\(title.id)")
                    }
                }
            }
            .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.disc.titles")
    }

    private func card(_ title: AppleDiscTitle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.name)
                .font(.headline)
                .foregroundStyle(.white)
            Text(title.durationLabel)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        #if os(tvOS)
        .frame(width: 300, alignment: .leading)
        .padding(24)
        #else
        .frame(width: 140, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        #endif
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }
}

/// The stream format badges as a wrapping row of grey outlined text badges.
struct AppleStreamFormatBadgeRow: View {
    let badges: [AppleStreamFormatBadge]

    var body: some View {
        AppleTitlePageFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(badges, id: \.self) { badge in
                AppleFormatBadge(text: badge.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badges.map(\.spokenName).joined(separator: ", "))
        .accessibilityIdentifier("detail.format-badges")
    }
}

/// The same badges, inline after a quality row's resolution.
struct AppleStreamFormatBadgeInline: View {
    let badges: [AppleStreamFormatBadge]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges, id: \.self) { badge in
                AppleFormatBadge(text: badge.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badges.map(\.spokenName).joined(separator: ", "))
    }
}
