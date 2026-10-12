import Foundation
import Testing
@testable import OpenStreamApple

// Edge cases for AppleOfflineQualityPolicy.bestVariant not covered by
// appleOfflinePolicyChoosesTheBestDeviceCompatibleVariant in CapabilityTests.swift.

private func makeDevice(
    maximumWidth: Int = 1920,
    maximumHeight: Int = 1080,
    codecs: Set<AppleVideoCodec> = [.avc, .hevc],
    dynamicRanges: Set<OpenStreamDynamicRange> = [.sdr, .hdr10],
    availableBytes: Int64 = 5_000_000_000
) -> AppleOfflineDeviceProfile {
    AppleOfflineDeviceProfile(
        maximumWidth: maximumWidth,
        maximumHeight: maximumHeight,
        codecs: codecs,
        dynamicRanges: dynamicRanges,
        availableBytes: availableBytes
    )
}

private func makeVariant(
    path: String = "variant.m3u8",
    width: Int = 1280,
    height: Int = 720,
    bitrate: Int = 3_000_000,
    codec: AppleVideoCodec = .avc,
    dynamicRange: OpenStreamDynamicRange = .sdr,
    estimatedBytes: Int64? = 1_000_000_000
) -> AppleOfflineVariant {
    AppleOfflineVariant(
        url: URL(string: "https://fixture.example/\(path)")!,
        width: width,
        height: height,
        bitrate: bitrate,
        codec: codec,
        dynamicRange: dynamicRange,
        estimatedBytes: estimatedBytes
    )
}

@Test func offlineQualityPolicyReturnsNilForAnEmptyVariantList() {
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [], for: makeDevice()) == nil)
}

@Test func offlineQualityPolicyReturnsNilWhenEveryVariantIsIncompatible() {
    let variants = [
        makeVariant(path: "too-big.m3u8", width: 3840, height: 2160),
        makeVariant(path: "wrong-range.m3u8", dynamicRange: .dolbyVision),
    ]
    let device = makeDevice(codecs: [.avc, .hevc], dynamicRanges: [.sdr])
    #expect(AppleOfflineQualityPolicy.bestVariant(from: variants, for: device) == nil)
}

@Test func offlineQualityPolicyIncludesVariantsExactlyAtTheDeviceMaximumDimensions() {
    let variant = makeVariant(path: "exact-fit.m3u8", width: 1920, height: 1080)
    let device = makeDevice(maximumWidth: 1920, maximumHeight: 1080)
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [variant], for: device)?.url
        == variant.url)
}

@Test func offlineQualityPolicyExcludesVariantsWithZeroWidthOrHeightEvenIfOtherwiseCompatible() {
    let zeroWidth = makeVariant(path: "zero-width.m3u8", width: 0, height: 720)
    let zeroHeight = makeVariant(path: "zero-height.m3u8", width: 1280, height: 0)
    let device = makeDevice()
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [zeroWidth], for: device) == nil)
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [zeroHeight], for: device) == nil)
}

@Test func offlineQualityPolicyAllowsAnUnknownCodecEvenWhenTheDeviceDeclaresNoCodecSupport() {
    let variant = makeVariant(path: "unknown-codec.m3u8", codec: .unknown)
    let device = makeDevice(codecs: [])
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [variant], for: device)?.url == variant.url)
}

@Test func offlineQualityPolicyTreatsANilEstimatedSizeAsZeroSoItAlwaysFitsAvailableSpace() {
    let variant = makeVariant(path: "unknown-size.m3u8", estimatedBytes: nil)
    let device = makeDevice(availableBytes: 0)
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [variant], for: device)?.url == variant.url)
}

@Test func offlineQualityPolicyExcludesAVariantWhoseEstimatedSizeExceedsAvailableSpace() {
    let variant = makeVariant(path: "too-large-to-store.m3u8", estimatedBytes: 6_000_000_000)
    let device = makeDevice(availableBytes: 5_000_000_000)
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [variant], for: device) == nil)
}

@Test func offlineQualityPolicyBreaksAnExactScoreTieByKeepingTheFirstListedVariant() {
    // Same width/height/codec/dynamicRange/bitrate score two ways to fetch the same
    // rendition (e.g. a CDN mirror); only the URL differs. Documents current
    // behaviour: `max(by:)` keeps the earlier element on an exact tie.
    let first = makeVariant(path: "mirror-a.m3u8")
    let secondMirror = makeVariant(path: "mirror-b.m3u8")
    let device = makeDevice()
    #expect(AppleOfflineQualityPolicy.bestVariant(from: [first, secondMirror], for: device)?.url
        == first.url)
}
