import Foundation
import os

/// Shares source bytes across display sizes without throttling disk hits or decode work.
actor AppleArtworkDownload {
    static let shared = AppleArtworkDownload()
    /// The image request's priority, set by `AppleRemoteImageCache` around its loader.
    @TaskLocal static var priority: AppleArtworkRequestQueue.Priority = .visible

    private struct Transfer {
        let id = UUID()
        let download: AppleRemoteImageCache.DataLoader
        var priority: AppleArtworkRequestQueue.Priority
        var consumers: [UUID: CheckedContinuation<(Data, URLResponse), any Error>]
        var task: Task<Void, Never>?
    }

    private var transfers: [URLRequest: Transfer] = [:]
    private var queued: [URLRequest] = []
    /// Every running non-foreground transfer, and the visible ones among them.
    private var activeByHost: [String: Int] = [:]
    private var visibleByHost: [String: Int] = [:]
    private let maximumConcurrentLoadsPerHost: Int
    var consumerCount: Int { transfers.values.reduce(0) { $0 + $1.consumers.count } }

    init(maximumConcurrentLoadsPerHost: Int = 3) {
        self.maximumConcurrentLoadsPerHost = max(1, maximumConcurrentLoadsPerHost)
    }

    func data(for request: URLRequest, download: @escaping AppleRemoteImageCache.DataLoader) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let consumer = UUID()
        let priority = Self.priority
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var transfer = transfers[request] {
                    transfer.consumers[consumer] = continuation
                    transfer.priority = max(transfer.priority, priority)
                    transfers[request] = transfer
                } else {
                    transfers[request] = Transfer(download: download, priority: priority, consumers: [consumer: continuation])
                    queued.append(request)
                }
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(request, consumer: consumer) }
        }
    }

    private func cancel(_ request: URLRequest, consumer: UUID) {
        guard var transfer = transfers[request], let continuation = transfer.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if transfer.consumers.isEmpty {
            transfer.task?.cancel()
            transfers[request] = nil
            queued.removeAll { $0 == request }
        } else {
            transfers[request] = transfer
        }
    }

    /// A load already waiting for its host moves up when on-screen art joins it.
    func promote(url: URL, to priority: AppleArtworkRequestQueue.Priority) {
        for request in queued where request.url == url {
            if let current = transfers[request]?.priority, current < priority { transfers[request]?.priority = priority }
        }
        startNext()
    }

    /// Highest priority first, oldest first within it. Foreground art is not
    /// held to the per-host limit, and visible art counts only other visible
    /// transfers, so prefetch never delays what is on screen: a row that
    /// appears starts its next-screen prefetch a moment before its tiles, and
    /// those used to hold the host's slots while a visible poster waited.
    private func nextQueuedIndex() -> Int? {
        var best: (index: Int, priority: AppleArtworkRequestQueue.Priority)?
        for (index, request) in queued.enumerated() {
            guard let priority = transfers[request]?.priority, best.map({ priority > $0.priority }) ?? true else { continue }
            let host = host(request)
            let canStart = switch priority {
            case .foreground: true
            case .visible: visibleByHost[host, default: 0] < maximumConcurrentLoadsPerHost
            case .prefetch: activeByHost[host, default: 0] < maximumConcurrentLoadsPerHost
            }
            if canStart { best = (index, priority) }
        }
        return best?.index
    }

    private func startNext() {
        while let index = nextQueuedIndex() {
            let request = queued.remove(at: index)
            guard var transfer = transfers[request] else { continue }
            // Foreground transfers neither wait for nor take a host slot.
            let host = transfer.priority == .foreground ? nil : host(request)
            let visible = transfer.priority == .visible
            if let host {
                activeByHost[host, default: 0] += 1
                if visible { visibleByHost[host, default: 0] += 1 }
            }
            let id = transfer.id
            let download = transfer.download
            transfer.task = Task {
                let interval = request.url.map { AppleArtworkTrace.begin("Artwork download", url: $0) } ?? .invalid
                if let url = request.url { AppleArtworkTrace.transferStarted(url: url) }
                defer {
                    if request.url != nil { AppleArtworkTrace.transferEnded() }
                    AppleArtworkTrace.end("Artwork download", id: interval)
                }
                let result: Result<(Data, URLResponse), any Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await download(request))
                } catch {
                    result = .failure(error)
                }
                complete(request, id: id, host: host, visible: visible, result: result)
            }
            transfers[request] = transfer
        }
    }

    private func complete(_ request: URLRequest, id: UUID, host: String?, visible: Bool,
                          result: Result<(Data, URLResponse), any Error>) {
        if let host {
            activeByHost[host, default: 0] -= 1
            if activeByHost[host] == 0 { activeByHost[host] = nil }
            if visible {
                visibleByHost[host, default: 0] -= 1
                if visibleByHost[host] == 0 { visibleByHost[host] = nil }
            }
        }
        if let transfer = transfers[request], transfer.id == id {
            transfers[request] = nil
            for continuation in transfer.consumers.values { continuation.resume(with: result) }
        }
        startNext()
    }

    private func host(_ request: URLRequest) -> String { request.url?.host?.lowercased() ?? "" }
}
