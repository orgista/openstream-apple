import Foundation
import Observation

/// Collects Up/Down channel presses and tunes once,
/// `AppleLiveZappingPolicy.coalesceDelay` after the last press. `pendingID`
/// is the channel the presses have reached so far, for the banner.
@MainActor
@Observable
final class AppleLiveZapCoalescer {
    private(set) var pendingID: String?
    @ObservationIgnored private var presses = 0
    /// The player's channel when the waiting presses were made.
    @ObservationIgnored private var pressedFrom: String?
    /// The last tune, until the player reports its channel: a press right
    /// after a commit still sees the previous channel as current.
    @ObservationIgnored private var committed: (from: String, to: String)?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private let delay: Duration

    init(delay: Duration = AppleLiveZappingPolicy.coalesceDelay) {
        self.delay = delay
    }

    func press(_ direction: AppleLiveZappingPolicy.Direction, currentID: String, orderedIDs: [String],
               commit: @escaping @MainActor (_ targetID: String, _ presses: Int) -> Void) {
        if committed?.from != currentID { committed = nil }
        let tunedID = committed?.to ?? currentID
        guard let next = AppleLiveZappingPolicy.target(currentID: pendingID ?? tunedID, orderedIDs: orderedIDs,
                                                       direction: direction) else { return }
        pendingID = next == tunedID ? nil : next
        pressedFrom = currentID
        presses += 1
        appleTrace("live surf \(direction == .next ? "up" : "down") → \(pendingID ?? tunedID)")
        commitTask?.cancel()
        commitTask = Task { [delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            let target = pendingID
            let count = presses
            reset()
            guard let target else { return }
            committed = (currentID, target)
            commit(target, count)
        }
    }

    /// A switch made any other way (a row, Last Channel, a link) drops the
    /// presses still waiting, so their tune cannot override it.
    func playerChanged(to id: String?) {
        guard commitTask != nil, id != pressedFrom, id != committed?.to else { return }
        appleTrace("live surf dropped: switched to \(id ?? "none")")
        cancel()
    }

    func cancel() {
        commitTask?.cancel()
        committed = nil
        reset()
    }

    private func reset() {
        commitTask = nil
        pendingID = nil
        pressedFrom = nil
        presses = 0
    }
}
