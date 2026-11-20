import Foundation
import Testing
@testable import OpenStreamApple

@Test func appleAssetInspectorSafelyHandlesNonFiniteAndNegativeDimensions() {
    #expect(AppleAssetInspector.safeDimension(Double.nan) == 0)
    #expect(AppleAssetInspector.safeDimension(Double.infinity) == 0)
    #expect(AppleAssetInspector.safeDimension(-Double.infinity) == 0)
    #expect(AppleAssetInspector.safeDimension(-1920.0) == 0)
    #expect(AppleAssetInspector.safeDimension(0.0) == 0)
    #expect(AppleAssetInspector.safeDimension(1920.0) == 1920)
    #expect(AppleAssetInspector.safeDimension(3840.5) == 3840)
    #expect(AppleAssetInspector.safeDimension(1e20) == 0)
    #expect(AppleAssetInspector.safeDimension(Double.greatestFiniteMagnitude) == 0)
    #expect(AppleAssetInspector.safeDimension(Double(Int.max)) == 0)

    #expect(AppleAssetInspector.safeFrameRate(Double.nan) == 0.0)
    #expect(AppleAssetInspector.safeFrameRate(Double.infinity) == 0.0)
    #expect(AppleAssetInspector.safeFrameRate(-Double.infinity) == 0.0)
    #expect(AppleAssetInspector.safeFrameRate(-60.0) == 0.0)
    #expect(AppleAssetInspector.safeFrameRate(0.0) == 0.0)
    #expect(AppleAssetInspector.safeFrameRate(23.976) == 23.976)
    #expect(AppleAssetInspector.safeFrameRate(60.0) == 60.0)
}

@Test func dolbyVisionConfigurationRejectsInvalidVersionAndExcessiveSize() {
    // Rejects unsupported major version (must be 1)
    let version0 = Data([0, 0, 16, 0b101, 0])
    let version2 = Data([2, 0, 16, 0b101, 0])
    let version255 = Data([255, 0, 16, 0b101, 0])
    #expect(DolbyVisionConfiguration(record: version0) == nil)
    #expect(DolbyVisionConfiguration(record: version2) == nil)
    #expect(DolbyVisionConfiguration(record: version255) == nil)

    // Rejects truncated payloads (< 5 bytes)
    #expect(DolbyVisionConfiguration(record: Data([])) == nil)
    #expect(DolbyVisionConfiguration(record: Data([1])) == nil)
    #expect(DolbyVisionConfiguration(record: Data([1, 0, 16, 0b101])) == nil)

    // Rejects oversized payloads (> 256 bytes)
    let oversized = Data([1, 0, 16, 0b101, 0]) + Data(repeating: 0, count: 252) // 257 bytes
    #expect(oversized.count == 257)
    #expect(DolbyVisionConfiguration(record: oversized) == nil)

    // Accepts max valid boundary payload (256 bytes)
    let maxValid = Data([1, 0, 16, 0b101, 0]) + Data(repeating: 0, count: 251) // 256 bytes
    #expect(maxValid.count == 256)
    let maxValidConfig = DolbyVisionConfiguration(record: maxValid)
    #expect(maxValidConfig?.profile == 8)

    // Rejects out-of-bounds profile (> 31)
    let invalidProfile = Data([1, 0, (32 << 1), 0b101, 0])
    #expect(DolbyVisionConfiguration(record: invalidProfile) == nil)

    // Valid profiles 5 and 7
    let profile5 = Data([1, 0, (5 << 1), 0b101, 0])
    let profile7 = Data([1, 0, (7 << 1), 0b101, 0])
    #expect(DolbyVisionConfiguration(record: profile5)?.openStreamProfile == .profile5)
    #expect(DolbyVisionConfiguration(record: profile7)?.openStreamProfile == .profile7)
}

@Test func appleOfflineMediaStoreEnforcesSandboxContainment() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: "openstream-containment-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let libraryDir = tempRoot.appending(path: "library", directoryHint: .isDirectory)
    let allowedDir = tempRoot.appending(path: "allowed", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)

    let store = AppleOfflineMediaStore(
        rootDirectory: libraryDir,
        allowedDirectories: [allowedDir, libraryDir]
    )

    // Verify uncontained system paths are rejected
    let passwdURL = URL(fileURLWithPath: "/etc/passwd")
    #expect(await store.isPathContained(passwdURL) == false)
    await #expect(throws: AppleOfflineStoreError.uncontainedSourceFileURL) {
        try await store.makeAvailable(mediaID: "exploit:1", sourceURL: passwdURL)
    }

    // Verify directory traversal attempts outside allowed scope are rejected
    let traversalURL = allowedDir.appending(path: "../../etc/passwd")
    #expect(await store.isPathContained(traversalURL) == false)
    await #expect(throws: AppleOfflineStoreError.uncontainedSourceFileURL) {
        try await store.makeAvailable(mediaID: "exploit:2", sourceURL: traversalURL)
    }

    // Verify contained non-existent file throws sourceFileNotFound
    let missingContained = allowedDir.appending(path: "nonexistent.mp4")
    #expect(await store.isPathContained(missingContained) == true)
    await #expect(throws: AppleOfflineStoreError.sourceFileNotFound) {
        try await store.makeAvailable(mediaID: "valid:missing", sourceURL: missingContained)
    }

    // Verify contained valid file succeeds
    let validSource = allowedDir.appending(path: "sample.mp4")
    try Data([0xaa, 0xbb, 0xcc]).write(to: validSource)
    let record = try await store.makeAvailable(mediaID: "valid:1", sourceURL: validSource)
    #expect(FileManager.default.fileExists(atPath: record.localURL.path))
    #expect(await store.record(for: "valid:1")?.mediaID == "valid:1")
}
