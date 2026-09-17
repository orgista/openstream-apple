import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Test func audioSessionWorkRunsOffMainAndPreservesActivationOrder() async throws {
    let queue = AppleAudioSessionWorkQueue()
    let recorder = AudioWorkRecorder()
    queue.enqueue { recorder.append("activate") }
    queue.enqueue { recorder.append("deactivate") }
    try await queue.perform { recorder.append("reactivate") }
    #expect(recorder.values == ["activate", "deactivate", "reactivate"])
    #expect(!recorder.usedMainThread)
}

private final class AudioWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var main = false
    var values: [String] { lock.withLock { storage } }
    var usedMainThread: Bool { lock.withLock { main } }
    func append(_ value: String) { lock.withLock { storage.append(value); main = main || Thread.isMainThread } }
}
