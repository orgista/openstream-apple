import Foundation
import Observation

/// Sequential season work keeps only one resolver and media transfer active.
/// A failed episode stops the queue; retry uses existing downloads to skip work.
@MainActor @Observable
final class AppleSeasonDownloadQueue {
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var failure: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start(episodeIDs: [String], download: @escaping @MainActor (String) async throws -> Void) {
        guard !isRunning else { return }
        var seen = Set<String>()
        let ids = episodeIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        completed = 0
        total = ids.count
        failure = nil
        isRunning = !ids.isEmpty
        let token = UUID()
        generation = token
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isRunning = false } }
            for id in ids {
                do {
                    try Task.checkCancellation()
                    try await download(id)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.completed += 1
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == token else { return }
                    self.failure = error.localizedDescription
                    return
                }
            }
        }
    }

    func cancel() {
        failure = nil
        work?.cancel()
    }
    func waitUntilFinished() async { await work?.value }
}

extension AppleOfflineDownloadCoordinator {
    /// Bridges the existing state machine without starting a second transfer.
    func downloadAndWait(
        request: Request,
        resolvePlans: @escaping PlanResolver,
        revokeCapabilities: @escaping CapabilityRevoker
    ) async throws {
        try Task.checkCancellation()
        if await record(for: request.mediaID) != nil { return }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                stateDidChange = { [weak self] state in
                    switch state {
                    case .completed:
                        self?.stateDidChange = nil
                        continuation.resume()
                    case .failed(_, let message):
                        self?.stateDidChange = nil
                        continuation.resume(throwing: SeasonFailure(message: message))
                    case .cancelled:
                        self?.stateDidChange = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                start(request: request, resolvePlans: resolvePlans, revokeCapabilities: revokeCapabilities)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private struct SeasonFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
