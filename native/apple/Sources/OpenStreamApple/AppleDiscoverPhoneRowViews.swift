import SwiftUI

extension EnvironmentValues {
    /// Set only on Discover's rails: N11's upright phone, the iPad and N13's
    /// Mac. Other screens keep their own look; pushed title pages clear it.
    @Entry var appleDiscoverRows: AppleDiscoverRowStyle? = nil
}

extension AppleDiscoverRowStyle {
    // The phone's are the N11 sizes. The Mac's type is a step up: a macOS
    // footnote is 10 pt, where the Figma asks for 13 pt titles and 12 pt meta.
    var headerFont: Font {
        switch platform {
        case .phone: .title3.bold()
        case .pad: .title3.weight(.semibold)
        case .mac: .title.bold()
        }
    }
    var headerChevronFont: Font {
        switch platform {
        case .phone: .body.weight(.bold)
        case .pad: .body.weight(.semibold)
        case .mac: .title3.weight(.bold)
        }
    }
    var captionTitleFont: Font {
        switch platform {
        case .phone: .footnote.weight(.semibold)
        case .pad: .footnote.weight(.semibold)
        case .mac: .body.weight(.semibold)
        }
    }
    var captionMetaFont: Font {
        switch platform {
        case .phone: .caption2
        case .pad: .caption2
        case .mac: .callout
        }
    }
    var posterTitleFont: Font {
        switch platform {
        case .phone: .caption.weight(.medium)
        case .pad: .caption.weight(.medium)
        case .mac: .callout.weight(.medium)
        }
    }
    var menuGlyphFont: Font {
        switch platform {
        case .phone: .footnote.weight(.bold)
        case .pad: .footnote.weight(.bold)
        case .mac: .body.weight(.bold)
        }
    }
    var rankNumeralSize: CGFloat {
        switch platform { case .phone: 40; case .pad: 52; case .mac: 52 }
    }
    var pillFontSize: CGFloat {
        switch platform { case .phone: 10; case .pad: 11; case .mac: 11 }
    }
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

/// The thin, inset progress bar shared by Continue Watching artwork on every platform.
struct AppleStillProgressBar: View {
    let progress: Double
    let width: CGFloat

    var body: some View {
        let inset = AppleCatalogCardMetrics.progressBarInset
        let barWidth = max(width - inset.horizontal * 2, 0)
        Capsule()
            .fill(AppleDesignTokens.artworkProgressTrack)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: barWidth * min(max(progress, 0), 1))
            }
            .frame(width: barWidth, height: AppleDiscoverPhoneRowMetrics.progressHeight)
            .background {
                Capsule()
                    .fill(AppleDesignTokens.artworkProgressBacking)
                    .padding(-AppleDesignTokens.artworkProgressBackingOutset)
            }
            .shadow(color: AppleDesignTokens.artworkProgressShadow, radius: 1)
            .padding(.bottom, inset.bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
