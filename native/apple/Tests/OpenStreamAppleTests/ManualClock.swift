import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// A clock that moves only when the test advances it, so a deadline fires on
/// cue however loaded the machine is. Sleepers wake in deadline order; a
/// cancelled sleeper throws `CancellationError` like `Task.sleep`. Times are
/// offsets from `start`.
final class ManualClock: AppleClock {
    private struct Sleeper {
        let id: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now: ContinuousClock.Instant
        var nextID = 0
        var sleepers: [Sleeper] = []
        var deadlines: [ContinuousClock.Instant] = []
    }

    let start: ContinuousClock.Instant
    private let state: Mutex<State>

    init() {
        let start = ContinuousClock.now
        self.start = start
        state = Mutex(State(now: start))
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }

    var requestedDeadlines: [Duration] { state.withLock { $0.deadlines.map { start.duration(to: $0) } } }

    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    /// The deadlines still waiting, earliest first.
    var pendingDeadlines: [Duration] {
        state.withLock { $0.sleepers.map { start.duration(to: $0.deadline) }.sorted() }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> Result<Void, any Error>? in
                    state.deadlines.append(deadline)
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    func advance(to offset: Duration) {
        advance(by: now.duration(to: start.advanced(by: offset)))
    }

    /// Returns once `count` sleeps have been asked for, whether or not they
    /// are still waiting.
    func waitForSleeps(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitFor("\(count) sleeps, saw \(requestedDeadlines)", sourceLocation: sourceLocation) {
            state.withLock { $0.deadlines.count >= count }
        }
    }

    /// Returns once a sleep until `offset` has been asked for.
    func waitForSleep(until offset: Duration, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = start.advanced(by: offset)
        await waitFor("a sleep until \(offset), saw \(requestedDeadlines)", sourceLocation: sourceLocation) {
            state.withLock { $0.deadlines.contains(deadline) }
        }
    }
}
