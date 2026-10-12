import SwiftUI

extension EnvironmentValues {
    /// Set inside Discover on an iPhone held upright (N11) and on the Mac
    /// (N13): shelves, cards and captions take the Apple TV app's row style
    /// at that style's sizes. Every other screen and platform leaves it nil
    /// and keeps its own look; pages pushed from Discover set it back to nil.
    @Entry var appleDiscoverRows: AppleDiscoverRowStyle? = nil
}

extension AppleDiscoverRowStyle {
    // The phone's are the N11 sizes. The Mac's type is a step up: a macOS
    // footnote is 10 pt, where the Figma asks for 13 pt titles and 12 pt meta.
    var headerFont: Font { platform == .phone ? .title3.bold() : .title.bold() }
    var headerChevronFont: Font { platform == .phone ? .body.weight(.bold) : .title3.weight(.bold) }
    var headerSpacing: CGFloat { platform == .phone ? 10 : 4 }
    var captionTitleFont: Font { platform == .phone ? .footnote.weight(.semibold) : .body.weight(.semibold) }
    var captionMetaFont: Font { platform == .phone ? .caption2 : .callout }
    var posterTitleFont: Font { platform == .phone ? .caption.weight(.medium) : .callout.weight(.medium) }
    var menuGlyphFont: Font { platform == .phone ? .footnote.weight(.bold) : .body.weight(.bold) }
    var rankNumeralSize: CGFloat { platform == .phone ? 40 : 52 }
    var pillFontSize: CGFloat { platform == .phone ? 10 : 11 }
}

/// Text clamped to a line budget at a word boundary (A4 note: never
/// mid-word). The budget is in lines, so it grows with Dynamic Type; the text
/// takes only the lines it needs, up to that budget, unless `reservesSpace`.
struct AppleWordClampedText: View {
    let text: String
    let lines: Int
    /// Take the whole budget however short the text. Poster rails need it:
    /// the lazy row sizes every card off the first one, so a two-line title
    /// after a one-line one was cut to its first line (trace, 2026-09-23).
    var reservesSpace = false

    var body: some View {
        let candidates = AppleWordClamp.candidates(text)
        AppleWordClampLayout(reservesSpace: reservesSpace) {
            // The probe: `lines` lines of the current font, never shown. A
            // glyph on every line: Text drops a trailing blank line, which
            // made "\n " measure one line short.
            Text(verbatim: Array(repeating: "X", count: max(lines, 1)).joined(separator: "\n"))
            ForEach(candidates.indices, id: \.self) { index in
                Text(verbatim: candidates[index])
            }
            // One word longer than the tile: the only case a word can be
            // cut, and the last line still ends in an ellipsis.
            Text(verbatim: candidates.last ?? text).lineLimit(lines)
        }
        // Left-aligned as in the Figma; a link label centres multi-line text.
        .multilineTextAlignment(.leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Measures the probe (first subview) for the line budget, then shows the
/// first candidate that fits it at the offered width. `ViewThatFits` was
/// tried first; inside a horizontal rail its height proposal is not the
/// budget, and it fell back to one-word captions at AX sizes.
struct AppleWordClampLayout: Layout {
    var reservesSpace = false

    /// The last choice per offered width. SwiftUI asks for the size more
    /// than once per pass and again on every update of the card, and each
    /// fresh choice measures the candidates one by one (the title page's
    /// episode cards, ~20 ms of its open on the Mac, N47). The probe's
    /// height is re-measured each time and keys the entry, so a new type
    /// size or line budget never reuses an old choice.
    struct Cache {
        var choices: [CGFloat?: (budget: CGFloat, index: Int, size: CGSize)] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let (_, size, budget) = choice(width: proposal.width, subviews: subviews, cache: &cache) else { return .zero }
        return CGSize(width: proposal.width ?? size.width,
                      height: reservesSpace ? max(size.height, budget.height) : size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let chosen = choice(width: bounds.width, subviews: subviews, cache: &cache)?.index
        for index in subviews.indices {
            if index == chosen {
                subviews[index].place(at: bounds.origin, anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: nil))
            } else {
                subviews[index].place(at: CGPoint(x: bounds.minX - 100_000, y: bounds.minY),
                                      anchor: .topLeading, proposal: .zero)
            }
        }
    }

    private func choice(width: CGFloat?, subviews: Subviews,
                        cache: inout Cache) -> (index: Int, size: CGSize, budget: CGSize)? {
        guard subviews.count > 1 else { return nil }
        let proposal = ProposedViewSize(width: width, height: nil)
        let budget = subviews[subviews.startIndex].sizeThatFits(proposal)
        if let cached = cache.choices[width], cached.budget == budget.height {
            return (cached.index, cached.size, budget)
        }
        var chosen: (index: Int, size: CGSize)?
        for index in subviews.indices.dropFirst() {
            let size = subviews[index].sizeThatFits(proposal)
            if size.height <= budget.height + 0.5 { chosen = (index, size); break }
        }
        if chosen == nil {
            let last = subviews.index(before: subviews.endIndex)
            chosen = (last, subviews[last].sizeThatFits(proposal))
        }
        guard let chosen else { return nil }
        cache.choices[width] = (budget.height, chosen.index, chosen.size)
        return (chosen.index, chosen.size, budget)
    }
}

/// A3: the rank sits outside the art, beside the caption under the tile.
struct AppleTop10RowCaption: View {
    let item: AppleCatalogItem
    let rank: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appleDiscoverRows) private var rowStyle

    var body: some View {
        let style = rowStyle ?? .phone
        // At AX sizes the numeral goes above the caption, so the title keeps
        // the tile's full width and wraps at words, not inside them.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            AppleTop10RankNumeral(rank: rank, size: style.rankNumeralSize)
            VStack(alignment: .leading, spacing: 2) {
                AppleWordClampedText(text: item.name, lines: dynamicTypeSize.isAccessibilitySize ? 3 : 1,
                                     reservesSpace: true)
                    .font(style.captionTitleFont)
                let subtitle = AppleCatalogShelfPolicy.rankedSubtitle(for: item)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(style.captionMetaFont)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }
        }
        .frame(width: style.rankedWidth, alignment: .leading)
    }
}

/// "57 MIN LEFT" on the top-left of a Continue Watching still.
struct AppleRemainingTimePill: View {
    let label: String
    var fontSize: CGFloat = 10

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .modifier(AppleRemainingTimePillGround())
            .padding(8)
            .accessibilityHidden(true)
    }
}

/// Liquid Glass on the 26 releases, tinted dark so white text holds over a
/// bright still; the dark chip over a material before that (and on visionOS,
/// which has no `glassEffect`).
private struct AppleRemainingTimePillGround: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        fallback(content)
        #else
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.6)), in: .rect(cornerRadius: 6))
        } else {
            fallback(content)
        }
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.black.opacity(0.7), in: .rect(cornerRadius: 6))
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
    }
}

/// The 3 pt bar along the bottom of a still, in the app accent.
struct AppleStillProgressBar: View {
    let progress: Double
    let width: CGFloat

    var body: some View {
        Rectangle()
            .fill(AppleDesignTokens.artworkProgressTrack)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(AppleDesignTokens.brandAccent)
                    .frame(width: width * min(max(progress, 0), 1))
            }
            .frame(height: AppleDiscoverPhoneRowMetrics.progressHeight)
            .background {
                Rectangle()
                    .fill(AppleDesignTokens.artworkProgressBacking)
                    .padding(-AppleDesignTokens.artworkProgressBackingOutset)
            }
            .shadow(color: AppleDesignTokens.artworkProgressShadow, radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// Review builds only: Continue Watching tiles for a simulator that has no
/// progress, so the row can be photographed without playing anything. The
/// tiles are real catalogue titles; the progress lives in memory and is never
/// written to the playback store or the media index.
enum AppleContinueWatchingFixture {
    static let launchKey = "OpenStreamDebugContinueWatching"
    static let count = 4

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: launchKey) }

    static func info(index: Int, type: String) -> AppleContinueWatchingTileInfo {
        // (fraction watched, minutes left or nil for an unknown length, S, E)
        let pattern: [(Double, Double?, Int, Int)] = [(0.40, 57, 1, 3), (0.72, 8, 2, 5), (0.20, 81, 3, 1), (0.55, nil, 1, 7)]
        let (fraction, minutesLeft, season, episode) = pattern[index % pattern.count]
        let partID = type == "movie" ? nil : "fixture:\(season):\(episode)"
        let label = minutesLeft.flatMap { left -> String? in
            let duration = left * 60 / (1 - fraction)
            return AppleContinueWatchingCaption.remainingLabel(position: duration * fraction, duration: duration)
        }
        return AppleContinueWatchingTileInfo(progress: fraction, remainingLabel: label,
                                             subtitle: AppleContinueWatchingCaption.subtitle(type: type, partID: partID))
    }
}
#endif
