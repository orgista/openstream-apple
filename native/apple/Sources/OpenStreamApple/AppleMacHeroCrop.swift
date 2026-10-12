import CoreGraphics

/// Which part of a picture the Mac hero shows: the art and its trailer are
/// drawn aspect-fill into the same hero, and a crossfade from one to the
/// other reads as a zoom unless both show the same fraction of themselves
/// about the same anchor (N44). Pure, so the gate can check it.
enum AppleMacHeroCrop {
    /// The part of `drawn` (a picture's on-screen rect) that `viewport`
    /// shows, as fractions of the picture: `0,0 1x1` is all of it.
    static func visibleFraction(of drawn: CGRect, through viewport: CGRect) -> CGRect {
        guard drawn.width > 0, drawn.height > 0 else { return .zero }
        return CGRect(x: (viewport.minX - drawn.minX) / drawn.width,
                      y: (viewport.minY - drawn.minY) / drawn.height,
                      width: viewport.width / drawn.width,
                      height: viewport.height / drawn.height)
    }
}
