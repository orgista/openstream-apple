import Foundation

/// AVAudioSession may wait synchronously on another process. Keep that wait
/// off the UI thread, with a single process-wide ordering for activate/stop.
final class AppleAudioSessionWorkQueue: Sendable {
    static let shared = AppleAudioSessionWorkQueue()
    private let queue = DispatchQueue(label: "com.orgista.openstream.audio-session", qos: .userInitiated)

    func enqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// The inline preview must own ambient audio before WebKit/AVPlayer starts.
    /// Only call from outside this queue (preview entry points use MainActor).
    func performSynchronously(_ work: () throws -> Void) rethrows {
        try queue.sync(execute: work)
    }

    // Enqueue before yielding the caller's MainActor, so a subsequent trailer
    // takeover can drain all earlier playback work in the correct order.
    @MainActor func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
        try Task.checkCancellation()
    }
}
