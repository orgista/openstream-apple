import Foundation

/// AVAudioSession may wait synchronously on another process. Keep that wait
/// off the UI thread, with a single process-wide ordering for activate/stop.
final class AppleAudioSessionWorkQueue: Sendable {
    static let shared = AppleAudioSessionWorkQueue()
    private let queue = DispatchQueue(label: "com.orgista.openstream.audio-session", qos: .userInitiated)

    func enqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
        try Task.checkCancellation()
    }
}
