import Foundation

@MainActor
final class AppleSphericalLoadQueue {
    private struct Job {
        let id: ObjectIdentifier
        let operation: @MainActor () async -> Void
    }

    private var pending: [Job] = []
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isClosed = false
    var activeCount: Int { active.count }
    var pendingCount: Int { pending.count }

    func submit(id: ObjectIdentifier, operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isClosed, pending.count < 16, active[id] == nil, !pending.contains(where: { $0.id == id }) else { return false }
        pending.append(Job(id: id, operation: operation))
        startPending()
        return true
    }

    func cancel(id: ObjectIdentifier) {
        pending.removeAll { $0.id == id }
        active[id]?.cancel()
    }

    func cancelAll() {
        isClosed = true
        pending.removeAll()
        for task in active.values { task.cancel() }
    }

    private func startPending() {
        while !isClosed, active.count < 2, !pending.isEmpty {
            let job = pending.removeFirst()
            active[job.id] = Task { @MainActor [weak self] in
                await job.operation()
                self?.active.removeValue(forKey: job.id)
                self?.startPending()
            }
        }
    }
}
