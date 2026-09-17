import CoreGraphics

/// Where the picture actually is inside a player, and therefore where a
/// subtitle belongs.
///
/// The overlay used to pin cues to the bottom of the **screen**. On Apple TV
/// the video is full-bleed so that is the bottom of the picture and the bug is
/// invisible; on a phone in portrait the video letterboxes into a band and the
/// caption floated roughly 450 pt below it, in the black (2026-09-16).
public enum AppleVideoFitting: Sendable {
    /// Most video is 16:9, and it is the right guess when a route cannot report
    /// its own dimensions.
    ///
    /// Guessing narrower than the truth is the safe direction: for a 2.39:1
    /// film the caption lands slightly **inside** the picture, which is what
    /// every other player does anyway. Guessing wider would push it back out
    /// into the letterbox, which is the fault being fixed.
    public static let assumedAspect: CGFloat = 16.0 / 9.0

    /// The picture's rect inside `container`, fitted and centred.
    public static func fittedRect(container: CGSize, videoSize: CGSize?) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let aspect = aspectRatio(of: videoSize) ?? assumedAspect
        let fittedHeight = container.width / aspect
        if fittedHeight <= container.height {
            return CGRect(
                x: 0,
                y: (container.height - fittedHeight) / 2,
                width: container.width,
                height: fittedHeight
            )
        }
        let fittedWidth = container.height * aspect
        return CGRect(
            x: (container.width - fittedWidth) / 2,
            y: 0,
            width: fittedWidth,
            height: container.height
        )
    }

    /// How far above the container's bottom edge a caption should sit so it
    /// rests just inside the picture.
    ///
    /// Never negative: when the video fills the container — Apple TV, or a
    /// phone in landscape — this is zero and the caption keeps its usual
    /// bottom inset, exactly as before.
    public static func captionBottomInset(container: CGSize, videoSize: CGSize?) -> CGFloat {
        let rect = fittedRect(container: container, videoSize: videoSize)
        guard rect.height > 0 else { return 0 }
        return max(0, container.height - rect.maxY)
    }

    static func aspectRatio(of size: CGSize?) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}
