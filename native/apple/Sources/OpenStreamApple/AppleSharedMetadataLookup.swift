import Foundation

/// Shared by library matching and canonical title identity resolution. Each
/// caller owns its wait; the last departing caller cancels the shared work.
actor AppleSharedMetadataLookup<Value: Sendable> {
    private struct Flight {
        let task: Task<Value, Error>
        var waiters: Set<UUID>
    }
    private var inFlight: [String: Flight] = [:]
    private var waiting: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    var activeWaiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    func value(for key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let waiter = UUID()
        let task: Task<Value, Error>
        if var flight = inFlight[key] {
            flight.waiters.insert(waiter)
            inFlight[key] = flight
            task = flight.task
        } else {
            task = Task { try await operation() }
            inFlight[key] = Flight(task: task, waiters: [waiter])
        }
        defer {
            releaseWaiter(key, waiter: waiter)
            cancelledWaiters.remove(waiter)
        }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                if cancelledWaiters.remove(waiter) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting[waiter] = continuation
                Task {
                    let result = await task.result
                    deliver(waiter, result)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, waiter: waiter) }
        }
        try Task.checkCancellation()
        return value
    }

    private func deliver(_ waiter: UUID, _ result: Result<Value, Error>) {
        waiting.removeValue(forKey: waiter)?.resume(with: result)
    }

    private func cancelWaiter(_ key: String, waiter: UUID) {
        if let continuation = waiting.removeValue(forKey: waiter) {
            continuation.resume(throwing: CancellationError())
        } else if inFlight[key]?.waiters.contains(waiter) == true {
            cancelledWaiters.insert(waiter)
        }
        releaseWaiter(key, waiter: waiter)
    }

    private func releaseWaiter(_ key: String, waiter: UUID) {
        guard var flight = inFlight[key], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight[key] = nil
        } else { inFlight[key] = flight }
    }
}

/// The operation and its transport must cooperate with cancellation. Both
/// outcomes are joined before returning, so no abandoned request survives.
func appleBoundedMetadataLookup<Value: Sendable>(
    timeout: Duration, clock: any AppleClock = AppleSystemClock(),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return value
        }
        group.addTask {
            try await clock.sleep(for: timeout)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
