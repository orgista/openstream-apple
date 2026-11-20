import SwiftUI

struct AppleTop10RankNumeral: View {
    let rank: Int
    @ScaledMetric private var numeralSize: CGFloat

    /// 72 pt beside the big cards; the iPhone Top 10 caption passes 40.
    init(rank: Int, size: CGFloat = 72) {
        self.rank = rank
        _numeralSize = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Text(rank, format: .number)
            .font(.system(size: numeralSize, weight: .black))
            .foregroundStyle(.gray)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
