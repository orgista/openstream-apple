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

    /// Where a bitmap subtitle object (PGS/DVB) goes inside `container`.
    ///
    /// The composition canvas is laid onto the picture width-aligned and
    /// centred, then the object keeps its authored rect on that canvas at the
    /// same scale. Width-aligned is what makes a 2.39:1 rip right: its canvas
    /// is still 1920×1080 while the picture is 1920×800, so the canvas
    /// overhangs the picture into the letterbox, exactly where the disc put
    /// the dialogue. An unknown canvas (`.zero`) is the picture itself. An
    /// object the overhang would push past the container's top or bottom edge
    /// is slid back inside it, never resized.
    public static func bitmapSubtitleFrame(
        rect: CGRect,
        canvasSize: CGSize,
        container: CGSize,
        videoSize: CGSize?
    ) -> CGRect {
        let video = fittedRect(container: container, videoSize: videoSize)
        guard video.width > 0 else { return .zero }
        var canvas = video
        if canvasSize.width > 0, canvasSize.height > 0 {
            let height = canvasSize.height * video.width / canvasSize.width
            canvas = CGRect(x: video.minX, y: video.midY - height / 2, width: video.width, height: height)
        }
        let height = rect.height * canvas.height
        let y = canvas.minY + rect.minY * canvas.height
        return CGRect(
            x: canvas.minX + rect.minX * canvas.width,
            y: min(max(y, 0), max(0, container.height - height)),
            width: rect.width * canvas.width,
            height: height
        )
    }

    static func aspectRatio(of size: CGSize?) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}
