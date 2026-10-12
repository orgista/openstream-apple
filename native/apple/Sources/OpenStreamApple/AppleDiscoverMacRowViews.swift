import SwiftUI

#if DEBUG
extension EnvironmentValues {
    /// Review builds: a tile drawn as if the pointer were over it, so the
    /// hover state can be photographed without moving the owner's pointer.
    @Entry var appleDebugTileHover = false
}

/// `-OpenStreamDebugRailHover YES`: every Mac rail shows its paging buttons
/// and pages forward once, and the second Continue Watching tile is drawn
/// hovered. Nothing is written anywhere.
enum AppleRailHoverFixture {
    static let launchKey = "OpenStreamDebugRailHover"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: launchKey) }
}

/// `-OpenStreamDebugTop10 YES`: the two Top 10 rails for a review build that
/// may not fetch the weekly list. The titles are the connected catalogues'
/// own, in their order; the ranking lives in memory and is never written.
enum AppleTop10Fixture {
    static let launchKey = "OpenStreamDebugTop10"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: launchKey) }

    static func week(sections: [AppleCatalogSection]) -> AppleNetflixTop10Week? {
        func entries(type: String, category: String) -> [AppleNetflixTop10Entry] {
            var names: [String] = []
            for section in sections where section.catalog.type == type {
                for item in section.items where !names.contains(item.name) { names.append(item.name) }
            }
            return names.prefix(10).enumerated().map {
                AppleNetflixTop10Entry(rank: $0.offset + 1, title: $0.element, seasonTitle: nil, category: category)
            }
        }
        let films = entries(type: "movie", category: "Films")
        let tv = entries(type: "series", category: "TV")
        guard !films.isEmpty || !tv.isEmpty else { return nil }
        return AppleNetflixTop10Week(week: .now, films: films, tv: tv)
    }
}
#endif

extension View {
    /// Discover rails on the Mac (N13): the pointer, or keyboard focus, over a
    /// tile lifts and brightens it, as in the Apple TV app. With Reduce Motion
    /// it only brightens. Every other platform is untouched.
    @ViewBuilder
    func appleRowTileLift(_ isEnabled: Bool) -> some View {
        #if os(macOS)
        modifier(AppleRowTileLift(isEnabled: isEnabled))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct AppleRowTileLift: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.appleDebugTileHover) private var debugHover
    #else
    private let debugHover = false
    #endif

    func body(content: Content) -> some View {
        let lifted = isEnabled && (isHovered || isFocused || debugHover)
        content
            .brightness(lifted ? 0.06 : 0)
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1)
            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 10, y: 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: lifted)
            .onHover { hovering in
                if isEnabled { isHovered = hovering }
            }
    }
}

/// A Discover rail on the Mac: the same scroll view as everywhere else, plus
/// ‹ › buttons at its edges while the pointer is over it, each paging most of
/// a window's width, and tiles without the bordered button platter a macOS
/// link draws by default (the Apple TV app has none). Trackpad scrolling is
/// the scroll view's own and keeps working either way.
///
/// It pages through `ScrollViewReader` to anchors laid behind the tiles every
/// `AppleRailPaging.anchorStep` points: a `ScrollPosition` point scroll on
/// this nested horizontal rail was ignored on macOS 27 (traced 2026-09-23).
struct AppleMacRail<Content: View>: View {
    /// How many equal tiles the rail holds, its inset and its gap, when the
    /// caller knows them: the ‹ › buttons then page by whole tiles and land
    /// each page's first tile under the header
    /// (`AppleRailPaging.tileAnchorIndex`). Nil keeps the 40 pt anchors.
    var tileCount: Int? = nil
    var inset: CGFloat = 0
    var gap: CGFloat = 0
    @ViewBuilder let content: Content
    @State private var geometry = AppleRailPaging.Geometry()
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                content
                    .background(alignment: .leading) { anchors }
            }
            .scrollIndicators(.never)
            .buttonStyle(.plain)
            .onScrollGeometryChange(for: AppleRailPaging.Geometry.self) { scroll in
                AppleRailPaging.Geometry(offset: scroll.contentOffset.x, contentWidth: scroll.contentSize.width,
                                         visibleWidth: scroll.containerSize.width)
            } action: { _, value in
                geometry = value
            }
            .overlay(alignment: .leading) { pageButton(forward: false, proxy: proxy) }
            .overlay(alignment: .trailing) { pageButton(forward: true, proxy: proxy) }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: showsButtons)
            #if DEBUG
            .task {
                guard AppleRailHoverFixture.isEnabled else { return }
                try? await Task.sleep(for: .seconds(4))
                // A rail whose tiles are still arriving has nothing to page
                // yet (the Top 10 rows fill in after their lookup), and a
                // page then is a no-op; wait for it, up to 20 s.
                for _ in 0..<40 where !AppleRailPaging.canPageForward(geometry) {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                // Unanimated: a headless window behind the owner's is
                // occluded, its display link idles, and an animated scroll
                // never leaves the start (traced 2026-09-23).
                page(forward: true, proxy: proxy, animated: false)
            }
            #endif
        }
    }

    private var anchors: some View {
        HStack(spacing: 0) {
            ForEach(0..<AppleRailPaging.anchorCount(contentWidth: geometry.contentWidth, step: anchorStep), id: \.self) { index in
                Color.clear
                    .frame(width: anchorStep)
                    .id(AppleRailPaging.anchorID(index))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tilePitch: CGFloat? {
        tileCount.flatMap { AppleRailPaging.tilePitch(contentWidth: geometry.contentWidth, tileCount: $0, inset: inset, gap: gap) }
    }

    private var anchorStep: CGFloat {
        guard let tilePitch, tilePitch > 0 else { return AppleRailPaging.anchorStep }
        return tilePitch
    }

    private var showsButtons: Bool {
        #if DEBUG
        if AppleRailHoverFixture.isEnabled { return true }
        #endif
        return isHovered
    }

    @ViewBuilder
    private func pageButton(forward: Bool, proxy: ScrollViewProxy) -> some View {
        let canPage = forward ? AppleRailPaging.canPageForward(geometry) : AppleRailPaging.canPageBack(geometry)
        if showsButtons && canPage {
            pageButtonBody(forward: forward) { page(forward: forward, proxy: proxy) }
            // The tiles are the keyboard path through a rail; moving focus
            // scrolls it. These are the pointer's.
            .focusable(false)
            .padding(.horizontal, 10)
            .accessibilityLabel(forward ? "Next" : "Previous")
            .transition(.opacity)
        }
    }

    /// A glass circle on macOS 26+, as the Tahoe Apple TV app draws its shelf
    /// arrows; the dark disc over a material before that.
    @ViewBuilder
    private func pageButtonBody(forward: Bool, action: @escaping () -> Void) -> some View {
        let chevron = Image(systemName: forward ? "chevron.right" : "chevron.left")
            .font(.title2.weight(.semibold))
        if #available(macOS 26, *) {
            Button(action: action) {
                chevron.frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        } else {
            Button(action: action) {
                chevron
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: .circle)
                    .background(.ultraThinMaterial, in: .circle)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
        }
    }

    private func page(forward: Bool, proxy: ScrollViewProxy, animated: Bool = true) {
        let index = if let tilePitch, tilePitch > 0 {
            AppleRailPaging.tileAnchorIndex(geometry, forward: forward, pitch: tilePitch, inset: inset)
        } else {
            AppleRailPaging.anchorIndex(for: AppleRailPaging.target(geometry, forward: forward))
        }
        appleTrace("mac rail page \(forward ? "forward" : "back") from \(Int(geometry.offset)) of \(Int(geometry.contentWidth)) pitch=\(Int(tilePitch ?? 0)) → anchor \(index)")
        let anchor = AppleRailPaging.anchorID(index)
        if reduceMotion || !animated {
            proxy.scrollTo(anchor, anchor: .leading)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(anchor, anchor: .leading) }
        }
    }
}
#endif
