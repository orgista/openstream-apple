#if os(iOS)
import SwiftUI

/// The Live tab's fixed category row (owner item 8): underlined text tabs
/// that never float or move, the selected one white with a 2 pt white
/// underline the width of its text, the others secondary; one search glyph
/// fixed at the trailing end. 17 pt semibold, the same size as the rows'
/// channel names, so the row does not read as an afterthought.
struct AppleLiveCategoryBar: View {
    let tabs: [String]
    @Binding var selection: String
    let onSearch: () -> Void
    let onGuide: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tabs: [String], selection: Binding<String>, onSearch: @escaping () -> Void,
         onGuide: (() -> Void)? = nil) {
        self.tabs = tabs
        _selection = selection
        self.onSearch = onSearch
        self.onGuide = onGuide
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 24) {
                        ForEach(tabs, id: \.self) { tab in
                            tabButton(tab)
                                .id(tab)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, tab in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(tab, anchor: .center)
                    }
                }
            }
            if let onGuide {
                Button(action: onGuide) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Guide")
                .accessibilityIdentifier("live.guide")
            }
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Search Channels")
            .accessibilityIdentifier("live.search")
        }
        .frame(height: 44)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.categories")
    }

    private func tabButton(_ tab: String) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = tab }
        } label: {
            Text(tab)
                .font(.body.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.white)
                        .frame(height: 2)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(minWidth: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("live.category.\(tab)")
    }
}
#endif
