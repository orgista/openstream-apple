import SwiftUI

struct AppleShelfHeading: View {
    let title: String
    @Environment(\.appleDiscoverRows) private var rowStyle
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(titleFont)
            Image(systemName: "chevron.right")
                .font(rowStyle?.headerChevronFont ?? .headline.bold())
                .foregroundStyle(rowStyle != nil ? .secondary : .primary)
        }
        .multilineTextAlignment(.leading)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: AppleTVBillboardMetrics.rowTitleFontSize, weight: .bold)
        #else
        rowStyle?.headerFont ?? .title.bold()
        #endif
    }
}
