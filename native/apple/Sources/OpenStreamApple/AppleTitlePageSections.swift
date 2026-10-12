import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The pieces of the title page below the hero, after the Apple TV app's
// (INSPO-TEARDOWN §7, PDF pages 11–16), shared by the iPhone (N17) and the
// Mac (N18). Each one takes plain values and closures; the page decides what
// is shown and omits a section with no data. On the Mac the page sets the
// Discover row style (`appleDiscoverRows`), and the pieces that read it take
// the Mac's type sizes; everywhere else it is nil and they are as on the iPhone.

/// The text styles a clamped paragraph can use. Each maps to a SwiftUI font
/// for drawing and a UIKit or AppKit one for measuring, so the two agree.
enum AppleClampedTextStyle: Sendable {
    case subheadline
    case footnote
    /// The Mac hero's synopsis: 13 pt there, where `.subheadline` is 11.
    case body

    var font: Font {
        switch self {
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .body: .body
        }
    }

    #if canImport(UIKit)
    var textStyle: UIFont.TextStyle {
        switch self {
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .body: .body
        }
    }
    #elseif canImport(AppKit)
    var textStyle: NSFont.TextStyle {
        switch self {
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .body: .body
        }
    }
    #endif
}

/// Where a long paragraph is cut so it ends on a whole word with room left
/// for "… MORE" on its last line. `AppleWordClampedText` does the same for
/// short captions by trying every prefix; a synopsis is long enough to want
/// a binary search, and MORE needs to know whether anything was cut.
enum AppleParagraphClamp {
    struct Result: Equatable {
        let visible: String
        let isTruncated: Bool
    }

    /// Binary-searches the longest run of whole words that, with `suffix`,
    /// still fits `lines` lines of `width`. `fits` does the measuring, so the
    /// search is testable without a font.
    static func clamp(_ text: String, suffix: String, fits: (String) -> Bool) -> Result {
        if fits(text) { return Result(visible: text, isTruncated: false) }
        var ends: [String.Index] = []
        var index = text.startIndex
        var inWord = false
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            if isSpace, inWord { ends.append(index) }
            inWord = !isSpace
            index = text.index(after: index)
        }
        var low = 0
        var high = ends.count - 1
        var best: String?
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(text[..<ends[middle]])
            if fits(candidate + suffix) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        // A first word too long for the space is cut by the text system
        // rather than dropped: showing nothing would be worse.
        return Result(visible: best ?? String(text.prefix(1)), isTruncated: true)
    }
}

/// A paragraph clamped to `lineLimit` lines at a word boundary — never
/// mid-word — ending "… MORE"; tapping it opens the whole text in place (A12).
/// Two more lines are allowed at the accessibility text sizes so the clamp
/// does not swallow the paragraph.
struct AppleMoreText: View {
    let text: String
    let lineLimit: Int
    var style: AppleClampedTextStyle = .subheadline

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var isExpanded = false

    private var effectiveLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? lineLimit + 2 : lineLimit
    }

    private var clamp: AppleParagraphClamp.Result {
        guard !isExpanded, width > 0 else { return .init(visible: text, isTruncated: false) }
        #if canImport(UIKit)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let font = UIFont.preferredFont(forTextStyle: style.textStyle, compatibleWith: traits)
        let moreFont = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let limitHeight = ceil(font.lineHeight * CGFloat(effectiveLineLimit)) + 1
        let measureWidth = max(1, width - 2)
        return AppleParagraphClamp.clamp(text, suffix: "…  MORE") { candidate in
            let attributed = NSMutableAttributedString(string: candidate, attributes: [.font: font])
            if candidate.hasSuffix("MORE") {
                attributed.addAttributes([.font: moreFont.withWeight(.bold)],
                                         range: NSRange(location: attributed.length - 4, length: 4))
            }
            let rect = attributed.boundingRect(
                with: CGSize(width: measureWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return ceil(rect.height) <= limitHeight
        }
        #elseif canImport(AppKit)
        // The Mac has no Dynamic Type; its text styles are fixed sizes.
        let font = NSFont.preferredFont(forTextStyle: style.textStyle)
        let moreFont = NSFont.preferredFont(forTextStyle: .caption1)
        let boldMore = NSFontManager.shared.convert(moreFont, toHaveTrait: .boldFontMask)
        let limitHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(effectiveLineLimit)) + 1
        let measureWidth = max(1, width - 2)
        return AppleParagraphClamp.clamp(text, suffix: "…  MORE") { candidate in
            let attributed = NSMutableAttributedString(string: candidate, attributes: [.font: font])
            if candidate.hasSuffix("MORE") {
                attributed.addAttributes([.font: boldMore],
                                         range: NSRange(location: attributed.length - 4, length: 4))
            }
            let rect = attributed.boundingRect(
                with: CGSize(width: measureWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return ceil(rect.height) <= limitHeight
        }
        #else
        return .init(visible: text, isTruncated: false)
        #endif
    }

    var body: some View {
        let clamp = clamp
        Group {
            if clamp.isTruncated {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isExpanded = true }
                } label: {
                    clampedText(clamp)
                }
                .buttonStyle(.plain)
                // VoiceOver reads the whole paragraph, not the clamped one.
                .accessibilityLabel(text)
                .accessibilityHint("Shows the full text")
            } else {
                // Plain text when it all fits: a short fact such as "1999" is
                // not a control, and an always-on action made it read and crawl
                // as a silent button (N22).
                clampedText(clamp)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    private func clampedText(_ clamp: AppleParagraphClamp.Result) -> some View {
        Group {
            if clamp.isTruncated {
                let more = Text("  MORE").font(.caption.weight(.bold)).foregroundStyle(.primary)
                Text("\(clamp.visible)…\(more)")
            } else {
                Text(text)
            }
        }
        .font(style.font)
        // The clamp decides the cut; this only guards a measuring miss.
        .lineLimit(isExpanded ? nil : effectiveLineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if canImport(UIKit)
private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif

/// A section title on the title page: "Trailers", "Cast & Crew", "About".
struct AppleTitlePageSectionTitle: View {
    let title: String
    @Environment(\.appleDiscoverRows) private var rowStyle

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            // The Mac's rail headers (N13), so every heading on the page matches.
            .font(rowStyle?.platform == .mac ? rowStyle?.headerFont ?? .title2.bold() : .title2.bold())
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The season control (A9): the current season with a chevron, opening a
/// list anchored to it — current season ticked and in bold, scrolled into
/// view on open, dismissed by a tap outside. One season is a plain label.
struct AppleTitlePageSeasonPicker: View {
    let seasons: [Int]
    @Binding var selection: Int?
    let name: (Int) -> String

    @State private var isPresented = false
    @State private var isHovered = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: Int? { selection ?? seasons.first }

    var body: some View {
        if seasons.count > 1 {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(current.map(name) ?? "Season")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .rotationEffect(.degrees(isPresented ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPresented)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                // Brighter under a pointer (iPad, Mac); a finger never hovers.
                .background(.white.opacity(isHovered ? 0.22 : 0.14), in: .capsule)
                .frame(minHeight: AppleDesignTokens.minimumActionSize)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            #if !os(tvOS)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            #endif
            // The iPhone title page only; Apple TV has its own season menu.
            #if !os(tvOS)
            // On the Mac below the control; on iPhone/iPad wherever there is room.
            .popover(isPresented: $isPresented, arrowEdge: Self.listEdge) {
                seasonList
                    .presentationCompactAdaptation(.popover)
            }
            #endif
            .accessibilityLabel("Season")
            .accessibilityValue(current.map(name) ?? "")
            .accessibilityHint("Shows the seasons")
            .accessibilityIdentifier("detail.season")
            #if DEBUG
            // `-OpenStreamDebugSeasonMenu YES` opens the list once the page
            // has filled, so a headless sweep can photograph it open.
            .task {
                guard UserDefaults.standard.bool(forKey: "OpenStreamDebugSeasonMenu") else { return }
                try? await Task.sleep(for: .seconds(6))
                isPresented = true
            }
            #endif
        } else if let season = current {
            Text(name(season))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(minHeight: AppleDesignTokens.minimumActionSize)
                .accessibilityIdentifier("detail.season")
        }
    }

    #if os(macOS)
    private static let listEdge: Edge? = .bottom
    #else
    /// The system's choice: the control sits low under the hero on first
    /// view, and a list forced below it ran into the tab bar with two rows
    /// showing and the current season scrolled out (UX tour 2026-10-08).
    private static let listEdge: Edge? = nil
    #endif

    private var seasonList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(seasons, id: \.self) { season in
                        let isCurrent = season == current
                        Button {
                            selection = season
                            isPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .opacity(isCurrent ? 1 : 0)
                                    .accessibilityHidden(true)
                                Text(name(season))
                                    .font(.body.weight(isCurrent ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: rowHeight)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(season)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .accessibilityIdentifier("detail.season.\(season)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .frame(width: 240, height: min(CGFloat(seasons.count) * rowHeight, 360))
    }
}

/// The title page's Rate control on iPhone and iPad: its button (the round
/// one beside My List, or the iPad's glyph over "Rate"), opening the three
/// ratings in a list anchored to it, as the season control does. A `Menu`
/// here was two elements to VoiceOver — "Rate" and, under it, the menu's own
/// unnamed button (N49 #18) — whatever modifiers wrapped it.
struct AppleTitlePageRatePicker<Label: View>: View {
    let rating: AppleTitleRating?
    let glyph: (AppleTitleRating?, Bool) -> String
    let onSelect: (AppleTitleRating) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPresented = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            choices
                .presentationCompactAdaptation(.popover)
        }
        #endif
        .accessibilityLabel("Rate")
        .accessibilityValue(rating?.title ?? "Not rated")
        .accessibilityHint("Shows the ratings")
        .accessibilityIdentifier("detail.rate")
    }

    private var choices: some View {
        VStack(spacing: 0) {
            ForEach(AppleTitleRating.selectableCases, id: \.rawValue) { value in
                let isCurrent = value == rating
                Button {
                    onSelect(value)
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: glyph(value, isCurrent))
                            .font(.body.weight(.semibold))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(value.title)
                            .font(.body.weight(isCurrent ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: rowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier("detail.rate.\(value.rawValue)")
            }
        }
        .frame(width: 240)
    }
}

/// One episode on the rail (A10): the 16:9 still with a tick once watched and
/// a progress line while part-watched, "EPISODE 8" over the title, and the
/// synopsis clamped at a word. Tapping it plays the episode; `accessory` (the
/// download control) sits at the end of the eyebrow line.
struct AppleTitlePageEpisodeCard<Accessory: View>: View {
    let episode: AppleStremioEpisode
    let eyebrow: String
    let isWatched: Bool
    let isSelected: Bool
    /// 0…1 through the episode the saved position names; nil otherwise.
    let progress: Double?
    let width: CGFloat
    /// The show's backdrop, for an episode with no still of its own.
    var seriesBackdropURL: URL? = nil
    let onPlay: () -> Void
    @ViewBuilder let accessory: Accessory

    @ScaledMetric(relativeTo: .caption2) private var accessoryInset: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appleDiscoverRows) private var rowStyle
    @State private var stillFailed = false

    private var synopsisLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    /// The Mac's text styles run two to three points smaller than the
    /// iPhone's, so its card steps each line up one style.
    private var isMac: Bool { rowStyle?.platform == .mac }

    private var stillHeight: CGFloat { width * 9 / 16 }

    private var title: String {
        episode.title.isEmpty ? episode.displayTitle : episode.title
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                still
                    .padding(.bottom, 4)
                Text(eyebrow)
                    .font(isMac ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .padding(.trailing, accessoryInset)
                Text(title)
                    .font(isMac ? .headline : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let overview = episode.overview {
                    AppleWordClampedText(text: overview, lines: synopsisLines)
                        .font(isMac ? .callout : .footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Play \(episode.displayTitle)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(episode.overview ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            accessory
                .padding(.top, stillHeight - 4)
        }
    }

    private var accessibilityValue: String {
        [eyebrow.capitalized, isWatched ? "Watched" : nil, progress != nil ? "In progress" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var still: some View {
        AppleRemoteImage(url: AppleEpisodeStillPolicy.url(still: episode.thumbnailURL, stillFailed: stillFailed,
                                                          seriesBackdrop: seriesBackdropURL),
                         placeholderSystemImage: "play.fill",
                         onFailure: { stillFailed = true })
            .onChange(of: episode.thumbnailURL) { stillFailed = false } // a new still gets its own try (review of 6ad1031)
            .frame(width: width, height: stillHeight)
            .background(.white.opacity(0.09))
            .overlay(alignment: .bottom) {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .font(.title3)
                        .padding(8)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            // The pointer or keyboard focus lifts it, as on the Mac's
            // Discover rails; nothing on any other platform.
            .appleRowTileLift(true)
    }
}

/// A placeholder episode card while the list loads (2184361).
struct AppleTitlePageEpisodePlaceholder: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))
                .frame(width: width, height: width * 9 / 16)
            Capsule().fill(.white.opacity(0.10)).frame(width: 80, height: 9)
            Capsule().fill(.white.opacity(0.12)).frame(width: width * 0.6, height: 12)
            Capsule().fill(.white.opacity(0.08)).frame(width: width * 0.9, height: 10)
            Capsule().fill(.white.opacity(0.08)).frame(width: width * 0.7, height: 10)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A trailer on the Trailers rail: its 16:9 still and a caption. Tapping it
/// plays it in the hero.
struct AppleTitlePageTrailerCard: View {
    let key: String
    let caption: String
    let width: CGFloat
    /// Pressed, and loading in the hero (N69).
    var isLoading = false
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                AppleRemoteImage(url: AppleTitlePagePolicy.trailerThumbnailURL(for: key), placeholderSystemImage: "play.rectangle")
                    .frame(width: width, height: width * 9 / 16)
                    .background(.white.opacity(0.09))
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .appleRowTileLift(true)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(caption)")
        .accessibilityValue(isLoading ? "Loading" : "")
        #if DEBUG
        .onChange(of: isLoading) { _, loading in appleTrace("title trailer card \(caption) loading=\(loading)") }
        #endif
        .accessibilityIdentifier("detail.trailer.\(key)")
    }
}

/// One person on the Cast & Crew rail (A12): a round portrait — their
/// initials when the metadata has no picture — then name and role.
struct AppleTitlePageCreditPortrait: View {
    let person: AppleCreditPerson

    @ScaledMetric private var side: CGFloat
    @Environment(\.appleDiscoverRows) private var rowStyle

    /// `side` is the portrait's diameter at the default text size.
    init(person: AppleCreditPerson, side: CGFloat = 84) {
        self.person = person
        _side = ScaledMetric(wrappedValue: side, relativeTo: .footnote)
    }

    private var isMac: Bool { rowStyle?.platform == .mac }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                Text(person.initials)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if let portraitURL = person.portraitURL {
                    // Cropped around the face (owner 2026-10-09).
                    AppleCreditPortraitImage(url: portraitURL)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.circle)
            .accessibilityHidden(true)
            Text(person.name)
                .font(isMac ? .callout.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let role = person.role {
                Text(role)
                    .font(isMac ? .footnote : .caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(width: max(side + 16, 100), alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// Label above value, one column (A13): values run from "2020" to a
/// two-hundred-character language list, which a two-column table cannot
/// hold. Long values clamp at a word with MORE.
struct AppleTitlePageFactList: View {
    let facts: [AppleTitlePagePolicy.Fact]
    /// Facts side by side, for a wide Mac window with no other block beside
    /// this one. Each keeps its label above its value.
    var columns = 1
    @Environment(\.appleDiscoverRows) private var rowStyle

    private var isMac: Bool { rowStyle?.platform == .mac }

    var body: some View {
        Group {
            if columns > 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .topLeading), count: columns),
                          alignment: .leading, spacing: 14) {
                    ForEach(facts, content: factView)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(facts, content: factView)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factView(_ fact: AppleTitlePagePolicy.Fact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.label)
                .font(isMac ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
            AppleMoreText(text: fact.value, lineLimit: 3, style: isMac ? .body : .subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Each accessibility chip from the hero, spelled out in plain words (A13).
struct AppleTitlePageAccessibilityGlossary: View {
    let entries: [(badge: String, meaning: String)]
    @Environment(\.appleDiscoverRows) private var rowStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entries, id: \.badge) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    AppleFormatBadge(entry.badge)
                        .accessibilityHidden(true)
                    Text(entry.meaning)
                        .font(rowStyle?.platform == .mac ? .body : .subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The capability chips under the hero ("4K  HDR  CC  SDH  AD"): outlined
/// badges that wrap onto a second line rather than shrink.
struct AppleTitlePageChipRow: View {
    let chips: [String]

    var body: some View {
        AppleTitlePageFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(chips, id: \.self) { chip in
                AppleFormatBadge(chip)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chips.map(Self.spokenName).joined(separator: ", "))
    }

    static func spokenName(_ chip: String) -> String {
        switch chip.uppercased() {
        case "CC": "Closed captions"
        case "SDH": "Subtitles for the deaf and hard of hearing"
        case "AD": "Audio description"
        case "HDR", "HDR10+": "High dynamic range"
        default: chip
        }
    }
}

/// Left-to-right rows that wrap, for the chip row.
struct AppleTitlePageFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The round grey buttons beside the title page's Play (My List, Download,
/// Rate), as the home hero's My List button.
struct AppleTitlePageRoundButtonLabel: View {
    let title: String
    let systemImage: String
    /// A spinner in place of the glyph, while a download is being prepared.
    var showsProgress = false

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        Group {
            if showsProgress {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .background(Color(white: 70.0 / 255.0).opacity(0.9), in: .circle)
        .contentShape(.circle)
    }
}
