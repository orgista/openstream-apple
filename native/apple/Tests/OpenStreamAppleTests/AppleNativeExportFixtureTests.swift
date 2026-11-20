import AVFoundation
import Foundation
import Testing
@testable import OpenStreamApple

private let nativeExportFixturesEnabled = ProcessInfo.processInfo.environment["PLAYBACK_ENGINE_TESTS"] == "1"

private func nativeExportFixture() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mp4-h264-aac.mp4")
}

@Test(.enabled(if: nativeExportFixturesEnabled))
func nativeExportConcurrentRequestsPublishOneValidFileWithoutPartials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exporter = AppleNativeMediaExporter(outputDirectory: directory)
    async let first = exporter.compatibleURL(for: nativeExportFixture())
    async let second = exporter.compatibleURL(for: nativeExportFixture())
    let results = try await [first, second]
    #expect(results[0] == results[1])
    #expect(try await AppleAssetInspector.inspect(url: results[0]).suitability.supportsDirectPlayback)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(!files.contains { $0.lastPathComponent.contains(".partial-") })
}

@MainActor
@Test(.enabled(if: nativeExportFixturesEnabled))
func nativeExportDoesNotReuseOldMediaAfterSourceReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-export-change-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try FileManager.default.copyItem(at: nativeExportFixture(), to: source)
    let exporter = AppleNativeMediaExporter(outputDirectory: root.appendingPathComponent("cache"))
    let first = try await exporter.compatibleURL(for: source)
    let firstDuration = try await AVURLAsset(url: first).load(.duration).seconds
    #expect(firstDuration > 5)
    let trimmed = root.appendingPathComponent("trimmed.mp4")
    let trim = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
    trim.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
    try await trim.export(to: trimmed, as: .mp4)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.moveItem(at: trimmed, to: source)
    let second = try await exporter.compatibleURL(for: source)
    let secondDuration = try await AVURLAsset(url: second).load(.duration).seconds
    #expect(secondDuration < 5)
    #expect(secondDuration > 3)
}

@Test(.enabled(if: nativeExportFixturesEnabled))
func nativeExportReplacesCorruptCacheWithoutLeavingPartialFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-export-corrupt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let exporter = AppleNativeMediaExporter(outputDirectory: root)
    let first = try await exporter.compatibleURL(for: nativeExportFixture())
    try Data("not an mp4".utf8).write(to: first, options: .atomic)
    let repaired = try await exporter.compatibleURL(for: nativeExportFixture())
    #expect(repaired == first)
    #expect(try await AppleAssetInspector.inspect(url: repaired).suitability.supportsDirectPlayback)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
}
