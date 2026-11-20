import CoreGraphics
import Testing
@testable import OpenStreamApple

/// Owner item 1 (2026-10-09): every face sits inside its cast circle.
@Suite struct AppleCreditPortraitCropTests {
    private let portrait = CGSize(width: 300, height: 450)

    @Test func withoutAFaceTheSquareSitsJustBelowTheTop() {
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: portrait, face: nil)
        #expect(rect.width == 300 && rect.height == 300)
        #expect(rect.minY > 0 && rect.minY < 50)
    }

    @Test func aFaceLowInThePhotoKeepsItsChin() {
        // A face from 45 % to 75 % of the height: the top-pinned crop (0…300)
        // cut it at 66.7 %.
        let face = CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.3)
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: portrait, face: face)
        #expect(rect.maxY >= face.maxY * portrait.height)
        #expect(rect.minY <= face.minY * portrait.height)
    }

    @Test func aFaceHighInThePhotoKeepsItsHair() {
        let face = CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.25)
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: portrait, face: face)
        #expect(rect.minY == 0)
        #expect(rect.maxY >= face.maxY * portrait.height)
    }

    @Test func theFaceHasRoomAboveIt() {
        let face = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.25)
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: portrait, face: face)
        #expect(face.minY * portrait.height - rect.minY >= rect.height * AppleCreditPortraitCrop.headroom - 1)
    }

    @Test func theSquareNeverLeavesThePhoto() {
        for y in stride(from: 0.0, through: 0.9, by: 0.1) {
            for x in stride(from: 0.0, through: 0.9, by: 0.3) {
                let face = CGRect(x: x, y: y, width: 0.1, height: 0.1)
                for size in [portrait, CGSize(width: 450, height: 300)] {
                    let rect = AppleCreditPortraitCrop.cropRect(imageSize: size, face: face)
                    #expect(rect.minX >= 0 && rect.minY >= 0)
                    #expect(rect.maxX <= size.width && rect.maxY <= size.height)
                }
            }
        }
    }

    @Test func aWidePhotoCentresTheSquareOnTheFace() {
        let wide = CGSize(width: 600, height: 300)
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: wide, face: CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.2))
        #expect(rect.width == 300)
        #expect(rect.minX == 300)
    }

    @Test func visionBoxesFlipToATopLeftOrigin() {
        let flipped = AppleCreditPortraitCrop.topLeftRect(fromVision: CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.2))
        #expect(abs(flipped.minY - 0.2) < 0.0001)
        #expect(abs(flipped.minX - 0.2) < 0.0001)
        #expect(AppleCreditPortraitCrop.largest([CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)])?.minX == 0.5)
        #expect(AppleCreditPortraitCrop.largest([]) == nil)
    }
}
