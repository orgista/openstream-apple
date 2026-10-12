import CoreGraphics

/// Sizes for the iPhone hero's page dots, after the Apple TV app: the active
/// page is a wider capsule that fills as its timer runs, the pages near it are
/// plain dots, and the ones furthest away shrink (the "tail").
public enum AppleHeroPageDots {
    public static let activeWidth: CGFloat = 20
    public static let dotSize: CGFloat = 6
    public static let tailSize: CGFloat = 4.5
    public static let farTailSize: CGFloat = 3
    public static let spacing: CGFloat = 6

    /// The frame of the dot at `position` when `index` is showing.
    public static func size(position: Int, index: Int, count: Int) -> CGSize {
        guard count > 0, (0 ..< count).contains(position) else { return .zero }
        if position == index { return CGSize(width: activeWidth, height: dotSize) }
        let side: CGFloat = switch abs(position - index) {
        case ...2: dotSize
        case 3: tailSize
        default: farTailSize
        }
        return CGSize(width: side, height: side)
    }
}
