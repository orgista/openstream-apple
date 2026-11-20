#if os(iOS) || os(visionOS)
import SwiftUI

struct AppleLiveCategoryBar: View {
    let tabs: [String]
    @Binding var selection: String
    let onSearch: () -> Void
    let onGuide: (() -> Void)?
    let usesParamountStyle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tabs: [String], selection: Binding<String>, onSearch: @escaping () -> Void,
         onGuide: (() -> Void)? = nil, usesParamountStyle: Bool = false) {
        self.tabs = tabs
        _selection = selection
        self.onSearch = onSearch
        self.onGuide = onGuide
        self.usesParamountStyle = usesParamountStyle
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: usesParamountStyle ? AppleLiveStagePolicy.phoneCategorySpacing : 24) {
                        ForEach(tabs, id: \.self) { tab in
                            tabButton(tab)
                                .id(tab)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: AppleDesignTokens.minimumActionSize)
                    .background {
                        if usesParamountStyle {
                            AppleLiveCategoryScrollLock().allowsHitTesting(false)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, tab in
                    if usesParamountStyle {
                        // The Paramount+ strip stays put: it scrolls only to uncover a chip cut off at its edge.
                        proxy.scrollTo(tab)
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo(tab, anchor: .center)
                        }
                    }
                }
            }
            if let onGuide {
                Button(action: onGuide) {
                    Image(systemName: "tablecells")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .appleHoverAffordance()
                .accessibilityLabel("Guide")
                .accessibilityIdentifier("live.guide")
            }
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .appleHoverAffordance()
            .padding(.trailing, 4)
            .accessibilityLabel("Search Channels")
            .accessibilityIdentifier("live.search")
        }
        // Chips and glyphs share one 44 pt row, so the glyphs sit on the labels' line.
        .frame(height: AppleDesignTokens.minimumActionSize)
        .padding(.top, usesParamountStyle ? AppleLiveStagePolicy.phoneCategoryRowTop : 0)
        .frame(height: categoryHeight, alignment: usesParamountStyle ? .top : .center)
        .background(usesParamountStyle ? AppleLiveStagePolicy.phonePanel : .black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.categories")
    }

    private var categoryHeight: CGFloat {
        usesParamountStyle ? AppleLiveStagePolicy.phoneCategoryHeight : AppleDesignTokens.minimumActionSize
    }

    private func tabButton(_ tab: String) -> some View {
        let isSelected = tab == selection
        return Button {
            if usesParamountStyle {
                selection = tab
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = tab }
            }
        } label: {
            Group {
                if usesParamountStyle {
                    // The underline is as wide as the label, not the 44 pt tap frame, and hangs
                    // under it without moving the label off the row's centre line.
                    paramountLabel(tab, isSelected: isSelected)
                        .overlay(alignment: .bottom) {
                            underline(height: AppleLiveStagePolicy.phoneCategoryUnderlineHeight, isSelected: isSelected)
                                .offset(y: AppleLiveStagePolicy.phoneCategoryUnderlineGap
                                    + AppleLiveStagePolicy.phoneCategoryUnderlineHeight)
                        }
                        .frame(minHeight: AppleDesignTokens.minimumActionSize)
                } else {
                    tabLabel(tab, isSelected: isSelected)
                        .frame(minHeight: categoryHeight)
                        .overlay(alignment: .bottom) { underline(height: 2, isSelected: isSelected) }
                }
            }
            .frame(minWidth: AppleDesignTokens.minimumActionSize, alignment: usesParamountStyle ? .leading : .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appleHoverAffordance()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("live.category.\(tab)")
    }

    private func tabLabel(_ tab: String, isSelected: Bool) -> some View {
        Text(tab)
            .font(.body.weight(.semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
    }

    /// Paramount+'s label: callout size, semibold only when selected. The width is the semibold
    /// one either way, so choosing a category never nudges the labels after it.
    private func paramountLabel(_ tab: String, isSelected: Bool) -> some View {
        Text(tab)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .overlay(alignment: .leading) {
                Text(tab)
                    .font(isSelected ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
    }

    private func underline(height: CGFloat, isSelected: Bool) -> some View {
        Rectangle()
            .fill(.white)
            .frame(height: height)
            .opacity(isSelected ? 1 : 0)
    }
}
#endif
