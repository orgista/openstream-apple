import CoreGraphics
import Testing
@testable import OpenStreamApple

/// N32 follow-ups #9, #10 and #16.
@Suite("iPad title page and card tile parity")
struct AppleN33ParityTests {
    /// #9: the iPad's text title was 17 pt body text.
    @Test func padTitleIsALargeTitleWithTheMacWordmarkBox() {
        #expect(AppleDetailMetrics.padTitleFontSize >= 34)
        #expect(AppleDetailMetrics.padTitleFontSize > AppleDetailMetrics.portraitTitleFontSize)
        #expect(AppleDetailMetrics.padTitleLogoMaxSize.height > AppleDetailMetrics.titleLogoMaxHeight)
    }

    /// #10: an episode rail shows a partial card at the edge, so it reads as scrollable.
    @Test("iPad episode cards leave a partial card at the edge", arguments: [
        (CGFloat(744), false), (834, false), (1024, false), (1133, true), (1194, true), (1366, true),
    ])
    func padEpisodeCardsLeaveAPartialCard(width: CGFloat, landscape: Bool) {
        let card = AppleDetailMetrics.padEpisodeCardWidth(viewportWidth: width, isLandscape: landscape)
        #expect((260 ... 360).contains(card))
        let across = (width - 16) / (card + 12)
        #expect(across.rounded(.down) != across)
        #expect(across >= 2)
    }

    @Test func padEpisodeCardHasAWidthBeforeTheViewportIsMeasured() {
        #expect(AppleDetailMetrics.padEpisodeCardWidth(viewportWidth: 0, isLandscape: false) == 300)
    }

    /// #16: a logo on a transparent or black plate draws on the card tile.
    @Test("A poster's plate is read from its border", arguments: [
        (UInt8(0), UInt8(255), AppleCatalogArtworkPolicy.Plate.black),
        (UInt8(2), UInt8(255), .black),
        (UInt8(30), UInt8(255), .none),
        (UInt8(200), UInt8(255), .none),
        (UInt8(0), UInt8(0), .transparent),
    ])
    func plateFromBorder(level: UInt8, alpha: UInt8, expected: AppleCatalogArtworkPolicy.Plate) throws {
        let image = try Self.image(border: level, alpha: alpha)
        #expect(AppleCatalogArtworkPolicy.plate(of: image) == expected)
    }

    @Test func aBandOfColourReachingTheEdgeIsStillAPlate() {
        var border = Array(repeating: (red: UInt8(0), green: UInt8(0), blue: UInt8(0), alpha: UInt8(255)), count: 56)
        for index in 0 ..< 6 { border[index] = (red: 30, green: 40, blue: 160, alpha: 255) }
        #expect(AppleCatalogArtworkPolicy.plate(border: border) == .black)
        for index in 0 ..< 20 { border[index] = (red: 30, green: 40, blue: 160, alpha: 255) }
        #expect(AppleCatalogArtworkPolicy.plate(border: border) == .none)
    }

    /// A 60 × 90 poster: `level` grey (at `alpha`) with a white logo block in the middle.
    private static func image(border level: UInt8, alpha: UInt8) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 60, height: 90, bitsPerComponent: 8, bytesPerRow: 240,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let value = CGFloat(level) / 255
        context.setFillColor(red: value, green: value, blue: value, alpha: CGFloat(alpha) / 255)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 15, y: 35, width: 30, height: 20))
        return try #require(context.makeImage())
    }
}
