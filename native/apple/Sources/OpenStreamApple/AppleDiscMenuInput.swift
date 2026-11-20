import CoreGraphics
import AetherEngine

/// The remote and pointer coordinates accepted by the disc navigator.
public enum AppleDiscMenuInput {
    public enum Direction: Sendable { case up, down, left, right }

    public static func direction(_ direction: Direction) -> DVDMenuDirection {
        switch direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    public static func normalizedPoint(_ point: CGPoint, container: CGSize, videoSize: CGSize?) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let picture = AppleVideoFitting.fittedRect(container: container, videoSize: videoSize)
        guard picture.width > 0, picture.height > 0, picture.contains(point) else { return nil }
        return CGPoint(x: (point.x - picture.minX) / picture.width,
                       y: (point.y - picture.minY) / picture.height)
    }
}
