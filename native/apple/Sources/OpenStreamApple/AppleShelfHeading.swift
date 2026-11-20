import SwiftUI

struct AppleShelfHeading: View {
    let title: String
    @Environment(\.appleDiscoverRows) private var rowStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(titleFont)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(rowStyle?.headerChevronFont ?? .headline.bold())
                .foregroundStyle(chevronStyle)
        }
        .multilineTextAlignment(.leading)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
    private var chevronStyle: HierarchicalShapeStyle {
        #if os(tvOS)
        // The See All cue: grey at rest, white with the lifted title on focus.
        isFocused ? .primary : .secondary
        #else
        rowStyle != nil ? .secondary : .primary
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: AppleTVBillboardMetrics.rowTitleFontSize, weight: .semibold)
        #else
        rowStyle?.headerFont ?? .title.bold()
        #endif
    }
}

extension View {
    /// A shelf heading that opens the full list. On Apple TV it stays a plain
    /// title, like Discover's, and focus lifts the words with no platter: the
    /// stock plain style's pill touched the posters under it (test Apple TV walk 9).
    func appleShelfHeadingButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(AppleTVShelfHeadingStyle())
        #else
        buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
private struct AppleTVShelfHeadingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                // Larger than a pill's 1.06: with no platter, the lift is the cue.
                .scaleEffect(isFocused ? 1.12 : 1, anchor: .leading)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 8, y: 4)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif
