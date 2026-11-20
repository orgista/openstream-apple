import Foundation

struct AppleHomeServiceLayout {
    static func buttonSize(regularWidth: Bool, platform: AppleUIPlatform = .current) -> CGSize {
        if platform == .tvOS { return CGSize(width: 300, height: 112) }
        return regularWidth ? CGSize(width: 200, height: 72) : CGSize(width: 140, height: 56)
    }

    let columnCount: Int
    let posterWidth: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat
    let inset: CGFloat

    init(width: CGFloat, regularWidth: Bool, platform: AppleUIPlatform = .current) {
        if platform == .tvOS {
            columnCount = 4
            posterWidth = AppleTVBillboardMetrics.posterWidth
            columnGap = AppleTVBillboardMetrics.cardGap
            rowGap = AppleTVBillboardMetrics.sectionSpacing
            inset = AppleTVBillboardMetrics.rowHorizontalInset
        } else {
            inset = regularWidth ? (width < 1180 ? 24 : 32) : 16
            columnGap = regularWidth ? 14 : 10
            rowGap = regularWidth ? 14 : 10
            let available = max(1, width - inset * 2)
            columnCount = regularWidth ? max(1, Int((available + columnGap) / (160 + columnGap))) : 3
            posterWidth = min(regularWidth ? 200 : .infinity,
                max(1, (available - CGFloat(columnCount - 1) * columnGap) / CGFloat(columnCount)))
        }
    }
}
