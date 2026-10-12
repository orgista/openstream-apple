import Foundation
import Observation

public struct AppleImportProgress: Sendable, Equatable {
    public enum Phase: Sendable { case downloading, parsing }
    public let phase: Phase
    public let items: Int
    public let bytes: Int
    public let totalBytes: Int
    public init(items: Int, bytes: Int, totalBytes: Int, phase: Phase = .parsing) {
        self.phase = phase
        self.items = items
        self.bytes = totalBytes > 0 ? min(max(0, bytes), totalBytes) : max(0, bytes)
        self.totalBytes = max(0, totalBytes)
    }
}

/// Owns cancellable imports independently of the page displaying their progress.
@MainActor
@Observable
final class AppleImportStore {
    static let shared = AppleImportStore()
    struct Operation: Identifiable {
        let id: UUID
        let title: String
        let unit: String
        var progress = AppleImportProgress(items: 0, bytes: 0, totalBytes: 0)
        let cancel: () -> Void
    }
    private(set) var operations: [Operation] = []

    func run<Value: Sendable>(title: String, unit: String,
        work: @escaping @Sendable (@escaping @Sendable (AppleImportProgress) -> Void) async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try await work { progress in
                Task { @MainActor in
                    guard let index = self.operations.firstIndex(where: { $0.id == id }) else { return }
                    self.operations[index].progress = progress
                }
            }
            try Task.checkCancellation()
            return value
        }
        operations.append(Operation(id: id, title: title, unit: unit, cancel: { worker.cancel() }))
        defer { operations.removeAll { $0.id == id } }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}
