import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// PGS/DVB objects drew ~2× too big, pinned bottom-centre, one of two: the
/// adapter dropped each object's rect, canvas and forced flag (Q4a8 §4).
@Suite("Bitmap subtitle geometry")
struct AppleBitmapSubtitleGeometryTests {
    private let canvas = CGSize(width: 1920, height: 1080)
    /// The harness's two-object composition, as the engine decoded it.
    private let dialogue = CGRect(x: 0.300, y: 0.884, width: 0.402, height: 0.056)
    private let sign = CGRect(x: 0.321, y: 0.078, width: 0.359, height: 0.050)

    private func frame(_ rect: CGRect, canvas: CGSize? = nil, container: CGSize, video: CGSize?) -> CGRect {
        AppleVideoFitting.bitmapSubtitleFrame(rect: rect, canvasSize: canvas ?? self.canvas,
                                              container: container, videoSize: video)
    }

    private func approx(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test func aSixteenNineCanvasOnSixteenNineVideoOnAppleTVIsOneToOne() {
        let tv = CGSize(width: 1920, height: 1080)
        let f = frame(dialogue, container: tv, video: CGSize(width: 1920, height: 1080))
        // 772×61 px object → 772×61 pt, where the disc put it (was 120 pt tall).
        #expect(approx(f, CGRect(x: 576, y: 954.72, width: 771.84, height: 60.48)))
    }

    @Test func onAPhoneTheObjectScalesWithThePicture() {
        let landscape = CGSize(width: 874, height: 402)
        let f = frame(dialogue, container: landscape, video: CGSize(width: 1920, height: 1080))
        let picture = AppleVideoFitting.fittedRect(container: landscape, videoSize: CGSize(width: 1920, height: 1080))
        let scale = picture.width / 1920
        #expect(abs(f.height - 60.48 * scale) < 0.01)
        #expect(abs(f.minX - (picture.minX + 576 * scale)) < 0.01)
        #expect(f.height < 23)
    }

    @Test func anObjectAtTheTopOfTheFrameStaysAtTheTop() {
        let tv = CGSize(width: 1920, height: 1080)
        let top = frame(sign, container: tv, video: CGSize(width: 1920, height: 1080))
        let bottom = frame(dialogue, container: tv, video: CGSize(width: 1920, height: 1080))
        #expect(approx(top, CGRect(x: 616.32, y: 84.24, width: 689.28, height: 54)))
        #expect(top.maxY < tv.height / 4)
        #expect(bottom.minY > tv.height * 3 / 4)

        // Phone portrait: the picture is a band in the middle; the sign sits
        // at the top of the band, not the top of the screen.
        let portrait = CGSize(width: 402, height: 874)
        let band = AppleVideoFitting.fittedRect(container: portrait, videoSize: CGSize(width: 1920, height: 1080))
        let topInBand = frame(sign, container: portrait, video: CGSize(width: 1920, height: 1080))
        #expect(topInBand.minY > band.minY)
        #expect(topInBand.maxY < band.minY + band.height / 4)
    }

    /// A 2.39:1 rip: picture 1920×800, PGS canvas still 1920×1080. The canvas
    /// is width-aligned to the picture and centred, so it overhangs into the
    /// letterbox exactly as the disc laid it out.
    @Test func aSixteenNineCanvasOnLetterboxedScopeVideoMapsOntoThePicture() {
        let scope = CGSize(width: 1920, height: 800)
        let tv = CGSize(width: 1920, height: 1080)
        let picture = AppleVideoFitting.fittedRect(container: tv, videoSize: scope)
        #expect(picture.minY == 140)
        // Dialogue authored in the lower bar lands in the lower bar.
        let low = frame(dialogue, container: tv, video: scope)
        #expect(approx(low, CGRect(x: 576, y: 954.72, width: 771.84, height: 60.48)))
        // An object authored inside the picture's top edge stays inside it.
        let inPicture = frame(CGRect(x: 0.3, y: 0.15, width: 0.4, height: 0.05), container: tv, video: scope)
        #expect(inPicture.minY >= picture.minY)
        #expect(inPicture.maxY < picture.midY)

        // Phone landscape is height-bound, so the real size matters: with the
        // 16:9 guess the object came out ~18 % too small.
        let landscape = CGSize(width: 874, height: 402)
        let real = frame(dialogue, container: landscape, video: scope)
        let guessed = frame(dialogue, container: landscape, video: nil)
        #expect(abs(real.width - 0.402 * 874) < 0.01)
        #expect(guessed.width < real.width * 0.85)
        // …and the overhanging canvas never pushes it off the screen.
        #expect(real.maxY <= landscape.height)
        #expect(frame(sign, container: landscape, video: scope).minY >= 0)
    }

    @Test("4K picture and HD PGS keep authored scale across rotation", arguments: [
        CGSize(width: 402, height: 874), CGSize(width: 874, height: 402),
        CGSize(width: 1920, height: 1080),
    ])
    func ultraHDPictureWithHDCanvas(container: CGSize) {
        let video = CGSize(width: 3840, height: 1608)
        let picture = AppleVideoFitting.fittedRect(container: container, videoSize: video)
        let result = frame(dialogue, container: container, video: video)
        #expect(abs(result.width - dialogue.width * picture.width) < 0.01)
        #expect(abs(result.height - dialogue.height * canvas.height * picture.width / canvas.width) < 0.01)
        #expect(containerRect(container).contains(result))
    }

    @Test func anObjectBeyondEitherHorizontalEdgeStaysVisible() {
        let container = CGSize(width: 402, height: 874)
        for x in [-0.1, 0.95] {
            let result = frame(CGRect(x: x, y: 0.8, width: 0.2, height: 0.05),
                               container: container, video: CGSize(width: 1920, height: 1080))
            #expect(containerRect(container).contains(result))
            #expect(abs(result.width - 80.4) < 0.01)
        }
    }

    @Test func oversizedObjectsShrinkUniformlyInsteadOfBeingCropped() {
        let container = CGSize(width: 874, height: 402)
        let result = frame(CGRect(x: -0.2, y: -0.2, width: 1.4, height: 1.4),
                           container: container, video: CGSize(width: 1920, height: 800))
        #expect(containerRect(container).contains(result))
        #expect(abs(result.height - container.height) < 0.01)
        #expect(abs(result.width / result.height - canvas.width / canvas.height) < 0.01)
    }

    @Test func invalidBitmapGeometryDrawsNothing() {
        let container = CGSize(width: 874, height: 402)
        for rect in [CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.1),
                     CGRect(x: 0, y: 0, width: -0.2, height: 0.1),
                     CGRect(x: 0, y: 0, width: 0.2, height: CGFloat.infinity)] {
            #expect(frame(rect, container: container, video: nil) == .zero)
        }
        #expect(frame(dialogue, container: CGSize(width: CGFloat.infinity, height: 402), video: nil) == .zero)
    }

    private func containerRect(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    @Test func anUnknownCanvasIsThePicture() {
        let tv = CGSize(width: 1920, height: 1080)
        let f = frame(dialogue, canvas: .zero, container: tv, video: nil)
        #expect(approx(f, CGRect(x: 576, y: 954.72, width: 771.84, height: 60.48)))
    }

    @Test func theAetherVideoSizeIsTheSoftwareSizeElseTheCodedSizeTimesThePixelAspect() {
        #expect(AetherPlaybackEngine.displaySize(software: CGSize(width: 1920, height: 800),
                                                 codedWidth: 1920, codedHeight: 1080, pixelAspect: 1)
                == CGSize(width: 1920, height: 800))
        #expect(AetherPlaybackEngine.displaySize(software: nil, codedWidth: 1920, codedHeight: 800, pixelAspect: 1)
                == CGSize(width: 1920, height: 800))
        // Anamorphic DVD: 720×480 at 32:27 presents at 853×480.
        #expect(AetherPlaybackEngine.displaySize(software: nil, codedWidth: 720, codedHeight: 480,
                                                 pixelAspect: 32.0 / 27.0) == CGSize(width: 853, height: 480))
        #expect(AetherPlaybackEngine.displaySize(software: nil, codedWidth: 0, codedHeight: 0, pixelAspect: 1) == nil)
    }
}
