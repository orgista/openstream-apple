#if canImport(AMSMB2)
import AMSMB2
import Foundation

/// One SMB file handle read front to back on AMSMB2's queue, handed out a
/// read at a time.
///
/// The bridge used to collect 4 MiB per `read` call, each one an SMB create,
/// read and close, before the player saw a byte (Infuse opens a file once per
/// play and reads it in place; REA round 4, fix 2). Here the file is opened
/// once per range and every read the share answers goes out as it lands.
/// The reading thread waits while a read is still unsent, so a paused player
/// holds one open handle and no growing memory, and a stream the player
/// abandons finishes at most the read in flight.
///
/// `@unchecked Sendable`: every mutable field is guarded by `condition`.
final class AppleSMBFileStream: AppleNetworkShareFileStream, @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var primed: Data?
    private var finished = false
    private var cancelled = false
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<Data?, any Error>?
    private let onEnd: @Sendable (ObjectIdentifier) -> Void

    /// `onEnd` runs once AMSMB2 has closed the file, with this stream's identifier.
    init(manager: SMB2Manager, path: String, range: Range<UInt64>,
         onEnd: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.onEnd = onEnd
        let end = range.upperBound
        manager.contents(atPath: path, offset: Int64(range.lowerBound), fetchedData: { [self] offset, _, data in
            let remaining = end - UInt64(offset)
            let piece = UInt64(data.count) > remaining ? data.prefix(Int(remaining)) : data
            return push(piece) && UInt64(offset) + UInt64(piece.count) < end
        }, completionHandler: { [self] error in
            finish(error)
        })
    }

    /// Waits for the first bytes, so an open that fails throws here.
    func prime() async throws {
        let first = try await nextFromReader()
        condition.withLock { primed = first }
    }

    func next() async throws -> Data? {
        let first = condition.withLock {
            defer { primed = nil }
            return primed
        }
        if let first { return first }
        return try await nextFromReader()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        chunks.removeAll()
        let waiter = waiter
        self.waiter = nil
        condition.broadcast()
        condition.unlock()
        waiter?.resume(throwing: CancellationError())
    }

    private func nextFromReader() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                condition.lock()
                if !chunks.isEmpty {
                    let data = chunks.removeFirst()
                    condition.broadcast()
                    condition.unlock()
                    continuation.resume(returning: data)
                } else if cancelled {
                    condition.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if finished {
                    let failure = failure
                    condition.unlock()
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: nil) }
                } else {
                    waiter = continuation
                    condition.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Runs on AMSMB2's queue; false stops the read and closes the file.
    private func push(_ data: Data) -> Bool {
        condition.lock()
        while !chunks.isEmpty, !cancelled { condition.wait() }
        guard !cancelled else {
            condition.unlock()
            return false
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: data)
        } else {
            chunks.append(data)
            condition.unlock()
        }
        return true
    }

    private func finish(_ error: (any Error)?) {
        condition.lock()
        finished = true
        failure = error
        let waiter = waiter
        self.waiter = nil
        condition.unlock()
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
        onEnd(ObjectIdentifier(self))
    }
}
#endif
