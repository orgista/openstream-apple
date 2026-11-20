#if os(visionOS)
import AVFoundation
import UniformTypeIdentifiers

/// Serves a tagged movie header without moving the original media samples.
// Restates AVURLAsset's Sendable conformance; the added references are immutable and Sendable.
@available(visionOS 26.0, *)
final class AppleSphericalTaggedAsset: AVURLAsset, @unchecked Sendable {
    let loader: AppleSphericalTagLoader
    let sourceURL: URL
    private let source: AppleSphericalByteSource

    @MainActor
    private init(url: URL, source: AppleSphericalByteSource, bytes: AppleSphericalAssetBytes, contentType: String) {
        self.source = source
        sourceURL = source.url
        loader = AppleSphericalTagLoader(source: source, bytes: bytes, contentType: contentType)
        super.init(url: url, options: [AVURLAssetShouldParseExternalSphericalTagsKey: true])
        resourceLoader.setDelegate(loader, queue: .main)
    }

    static func make(source: AppleSphericalByteSource, filename: String, boxes: [UInt8]) async throws -> AppleSphericalTaggedAsset? {
        let length = try await source.size()
        guard let bytes = try await AppleSphericalAssetBytes.make(length: length, boxes: boxes, read: source.read) else { return nil }
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "openstream-vr"
        components.host = "media"
        components.path = "/" + filename
        guard let url = components.url else { throw URLError(.badURL) }
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .mpeg4Movie
        return await AppleSphericalTaggedAsset(url: url, source: source, bytes: bytes, contentType: type.identifier)
    }

    override func cancelLoading() {
        source.cancel()
        Task { @MainActor [loader] in loader.cancel() }
        super.cancelLoading()
    }

    deinit { source.cancel() }
}

// AVFoundation invokes this delegate on the main queue selected above. Loading requests
// and their data requests stay on that actor, including across asynchronous reads.
@MainActor
final class AppleSphericalTagLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    private let source: AppleSphericalByteSource
    private let bytes: AppleSphericalAssetBytes
    private let contentType: String
    private let loads = AppleSphericalLoadQueue()

    init(source: AppleSphericalByteSource, bytes: AppleSphericalAssetBytes, contentType: String) {
        self.source = source
        self.bytes = bytes
        self.contentType = contentType
    }

    func cancel() {
        loads.cancelAll()
        source.cancel()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = bytes.totalLength
            information.isByteRangeAccessSupported = true
        }
        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let (requestedEnd, overflow) = request.requestedOffset.addingReportingOverflow(Int64(request.requestedLength))
        let start = request.currentOffset
        let end = request.requestsAllDataToEndOfResource ? bytes.totalLength : min(bytes.totalLength, requestedEnd)
        guard !overflow, start >= 0, start <= end else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return true
        }
        let accepted = loads.submit(id: ObjectIdentifier(loadingRequest)) { [weak self] in
            guard let self else { return }
            do {
                var offset = start
                while offset < end {
                    try Task.checkCancellation()
                    let part = try await self.bytes.bytes(in: offset..<min(end, offset + AppleSphericalAssetBytes.chunkSize),
                                                          read: self.source.read)
                    guard !Task.isCancelled, !loadingRequest.isCancelled else { return }
                    request.respond(with: part)
                    offset += Int64(part.count)
                }
                if !loadingRequest.isCancelled, !Task.isCancelled { loadingRequest.finishLoading() }
            } catch {
                if !loadingRequest.isCancelled, !Task.isCancelled { loadingRequest.finishLoading(with: error) }
            }
        }
        if !accepted { loadingRequest.finishLoading(with: URLError(.resourceUnavailable)) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        loads.cancel(id: ObjectIdentifier(loadingRequest))
    }
}
#endif
