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

    static func tapFrames(index: Int, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let side = AppleDesignTokens.minimumActionSize
        var leading = side / 2
        return (0 ..< count).map { position in
            let dot = size(position: position, index: index, count: count)
            let edgePadding = position == 0 || position == count - 1 ? dot.width / 2 : 0
            let frame = CGRect(x: leading + dot.width / 2 - side / 2 - edgePadding,
                               y: 0, width: side + 2 * edgePadding, height: side)
            leading += dot.width + spacing
            return frame
        }
    }

    static func page(at point: CGPoint, frames: [CGRect]) -> Int? {
        frames.indices.filter { frames[$0].contains(point) }.min {
            abs(frames[$0].midX - point.x) < abs(frames[$1].midX - point.x)
        }
    }

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
