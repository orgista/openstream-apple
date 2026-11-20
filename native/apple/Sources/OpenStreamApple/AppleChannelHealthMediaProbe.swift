import Foundation
import Synchronization
import AetherEngine

/// The bundled libav probe reads only the bytes already fetched. No URL is passed to FFmpeg.
enum AppleChannelHealthMediaProbe {
    // Synchronous libav work has its own serial queue rather than blocking cooperative executors.
    private static let queue = DispatchQueue(label: "openstream.channel-health.media", qos: .utility)

    static func formatHint(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(400))
        if bytes.count > 188, bytes[0] == 0x47, bytes[188] == 0x47 { return "mpegts" }
        if bytes.count >= 8, ["ftyp", "styp", "moov"].contains(String(decoding: bytes[4..<8], as: UTF8.self)) { return "mov" }
        if bytes.count > 2, bytes[0] == 0xff, bytes[1] & 0xf6 == 0xf0 { return "aac" }
        if bytes.starts(with: [0x49, 0x44, 0x33]) { return "aac" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "wav" }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return "matroska" }
        return nil
    }

    static func inspect(_ data: Data, timeout: TimeInterval) async throws -> AppleChannelHealthVideoInfo {
        let reader = Reader(data: data, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: AppleChannelHealthVideoInfo = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !reader.stopped else { throw URLError(.timedOut) }
                        let probe = try AetherEngine.probe(source: .custom(reader, formatHint: formatHint(data)))
                        continuation.resume(returning: .init(codec: probe.videoCodecName,
                            width: Int(probe.videoWidth), height: Int(probe.videoHeight),
                            fps: probe.videoFrameRate, hasVideo: probe.videoCodecID != 0))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { reader.cancel() }
    }

    /// All cursor/cancellation state is mutex-protected; read/seek never block on I/O.
    private final class Reader: IOReader, Sendable {
        private struct State { var position = 0; var cancelled = false; var reads = 0 }
        private let state = Mutex(State())
        private let data: Data
        private let deadline: ContinuousClock.Instant
        var discImageProbeEnabled: Bool { false }
        init(data: Data, timeout: TimeInterval) {
            self.data = data
            deadline = .now.advanced(by: .seconds(timeout))
        }
        var stopped: Bool { state.withLock { $0.cancelled } || ContinuousClock.now >= deadline }
        func cancel() { state.withLock { $0.cancelled = true } }
        func close() { cancel() }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return state.withLock { value in
                guard !value.cancelled, ContinuousClock.now < deadline, value.reads < 4096 else { return -1 }
                value.reads += 1
                let count = min(Int(size), data.count - value.position)
                guard count > 0 else { return 0 }
                data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: count),
                               from: value.position..<(value.position + count))
                value.position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            state.withLock { value in
                guard !value.cancelled, ContinuousClock.now < deadline else { return -1 }
                if whence == 65536 { return Int64(data.count) }
                let base: Int64
                switch whence {
                case SEEK_SET: base = 0
                case SEEK_CUR: base = Int64(value.position)
                case SEEK_END: base = Int64(data.count)
                default: return -1
                }
                let (target, overflow) = base.addingReportingOverflow(offset)
                guard !overflow, target >= 0, target <= data.count else { return -1 }
                value.position = Int(target)
                return target
            }
        }
    }
}
