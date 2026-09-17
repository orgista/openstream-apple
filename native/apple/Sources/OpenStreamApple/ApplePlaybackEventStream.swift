import Foundation

@MainActor
final class ApplePlaybackEventStream {
    private var subscribers: [UUID: AsyncStream<ApplePlaybackEngineEvent>.Continuation] = [:]
    var subscriberCount: Int { subscribers.count }

    func stream() -> AsyncStream<ApplePlaybackEngineEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func emit(_ event: ApplePlaybackEngineEvent) {
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(event) { subscribers.removeValue(forKey: id) }
        }
    }

    isolated deinit {
        for continuation in subscribers.values { continuation.finish() }
    }
}
