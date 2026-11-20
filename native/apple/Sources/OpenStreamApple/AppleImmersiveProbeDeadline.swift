import Foundation
import Synchronization

enum AppleImmersiveProbeDeadline {
    /// A task group would wait for an AVFoundation load that ignores cancellation.
    static func run<Value: Sendable>(timeout: Duration = .seconds(3),
                                    cancel: @escaping @Sendable () -> Void,
                                    operation: @escaping @Sendable () async -> Value?) async -> Value? {
        guard !Task.isCancelled else { cancel(); return nil }
        let (results, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let finished = Mutex(false)
        let work = Task {
            let value = await operation()
            let won = finished.withLock { finished in
                if finished { return false }
                finished = true
                return true
            }
            guard won else { return }
            if let value { continuation.yield(value) }
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            let won = finished.withLock { finished in
                if finished { return false }
                finished = true
                return true
            }
            guard won else { return }
            cancel()
            work.cancel()
            continuation.finish()
        }
        defer {
            work.cancel()
            deadline.cancel()
            continuation.finish()
        }
        return await withTaskCancellationHandler {
            for await value in results { return value }
            return nil
        } onCancel: {
            cancel()
            work.cancel()
            continuation.finish()
        }
    }
}
