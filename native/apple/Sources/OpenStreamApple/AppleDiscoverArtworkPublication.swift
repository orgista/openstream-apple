import Foundation

enum AppleDiscoverArtworkPublication {
    enum Outcome: Equatable, Sendable { case ready, failed, cancelled }

    @concurrent nonisolated static func warm(_ requests: [AppleArtworkPrefetchPolicy.Request],
        load: @escaping @Sendable (AppleArtworkPrefetchPolicy.Request) async throws -> Void = { request in
            _ = try await AppleRemoteImageCache.shared.image(url: request.url,
                maximumPixelDimension: request.maximumPixelDimension, priority: .prefetch)
        }) async -> Outcome {
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        try await load(request)
                        try Task.checkCancellation()
                        return .ready
                    } catch is CancellationError { return .cancelled }
                    catch { return .failed }
                }
            }
            var outcome = Outcome.ready
            for await result in group {
                if result == .cancelled { outcome = .cancelled }
                else if result == .failed, outcome != .cancelled { outcome = .failed }
            }
            return outcome
        }
        return Task.isCancelled ? .cancelled : outcome
    }
}
