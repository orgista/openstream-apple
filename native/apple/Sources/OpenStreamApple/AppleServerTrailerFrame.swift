import CoreGraphics

/// Where a hero's server trailer draws over its still (seamless handover,
/// 2026-10-29). The still is aspect-filled and pinned top-leading
/// (`AppleRemoteImage` with no `fillAlignment`); the video is aspect-filled
/// into the rect the still draws in, so a still and trailer of the same
/// shape land on the same pixels and the crossfade never reads as a jump.
/// A letterboxed trailer's picture band is then made to cover the hero, as
/// the Mac's is (`AppleTrailerPreviewLayout.coveringPicture`, N62).
enum AppleServerTrailerFrame {
    static func videoFrame(in size: CGSize, art: CGSize?, video: CGSize,
                           pictureWindow: ClosedRange<CGFloat> = 0...1) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0, video.width > 0, video.height > 0 else { return bounds }
        let drawn = art.map { CGRect(origin: .zero, size: AppleTrailerPreviewLayout.aspectFillFrame(of: $0, in: size).size) }
            ?? bounds
        let raster = AppleTrailerPreviewLayout.aspectFillFrame(of: video, in: drawn.size)
            .offsetBy(dx: drawn.minX, dy: drawn.minY)
        return AppleTrailerPreviewLayout.coveringPicture(raster, in: size, pictureWindow: pictureWindow)
    }
}
