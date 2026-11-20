import Foundation

enum AppleDiscoverTop10Publication {
    struct Snapshot: Equatable, Sendable {
        let items: [AppleCatalogItem]
        let preferredSource: String?
        let requests: [AppleArtworkPrefetchPolicy.Request]
        var viewportReady = true
    }

    static func candidate(feed: [AppleCatalogItem], fallback: AppleTop10Store.Chart?,
        enabled: Bool, metadataAvailable: Bool) -> AppleTop10Store.Chart? {
        guard enabled else { return nil }
        if !feed.isEmpty { return .init(items: feed, fetchedAt: .distantPast) }
        return metadataAvailable ? fallback : nil
    }

    static func visible(_ chart: AppleTop10Store.Chart?, publishedSource: String,
        preferredSource: String?) -> AppleTop10Store.Chart? {
        guard let preferredSource, preferredSource == publishedSource else { return nil }
        return chart
    }

    @concurrent nonisolated static func readyChart(_ chart: AppleTop10Store.Chart,
        requests: [AppleArtworkPrefetchPolicy.Request], allowsArtworkFailure: Bool = false,
        load: @escaping @Sendable (AppleArtworkPrefetchPolicy.Request) async throws -> Void = { request in
            _ = try await AppleRemoteImageCache.shared.image(url: request.url,
                maximumPixelDimension: request.maximumPixelDimension, priority: .prefetch)
        }) async -> AppleTop10Store.Chart? {
        let outcome = await AppleDiscoverArtworkPublication.warm(requests, load: load)
        switch outcome {
        case .ready: return chart
        case .failed: return allowsArtworkFailure ? chart : nil
        case .cancelled: return nil
        }
    }
}
