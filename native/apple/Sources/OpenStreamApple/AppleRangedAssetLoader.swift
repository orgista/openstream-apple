import AVFoundation
import Foundation

/// Feeds AVFoundation a remote file that only answers ranged requests.
///
/// The trailer streams are served by hosts that return **403 to a `HEAD` and to
/// a `GET` without a `Range` header**, and 206 to everything ranged — measured
/// 2026-09-15 against the real Gentlemen trailer. AVFoundation opens a remote
/// asset with exactly those unranged requests to learn its length and type, so
/// `AVURLAsset` could never open one: it failed with `CoreMediaErrorDomain
/// -12660` before reading a byte. No combination of headers fixes that, because
/// the problem is the *absence* of `Range` on a request the framework makes
/// itself.
///
/// So the asset is handed a custom scheme instead, which routes every read
/// through here, and each read goes out as an explicit ranged `GET`.
final class AppleRangedAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// Swapped in for `https` so AVFoundation hands the load to this delegate
    /// rather than fetching the URL itself.
    static let scheme = "openstream-ranged"

    private let origin: URL
    private let contentType: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.orgista.openstream.ranged-asset")
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    /// - Parameter contentType: the UTI AVFoundation should assume, since the
    ///   usual way of learning it — an unranged request — is refused.
    init(origin: URL, contentType: String, session: URLSession = .shared) {
        self.origin = origin
        self.contentType = contentType
        self.session = session
    }

    /// An asset whose reads all come back through this delegate. The caller
    /// must keep the loader alive for as long as the asset is in use;
    /// `AVURLAsset` does not retain its resource-loader delegate.
    static func asset(for url: URL, contentType: String) -> (AVURLAsset, AppleRangedAssetLoader)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        guard let redirected = components.url else { return nil }
        let loader = AppleRangedAssetLoader(origin: url, contentType: contentType)
        let asset = AVURLAsset(url: redirected)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // A content-information request only needs the total size, which the
        // Content-Range of a one-byte read reports.
        if let info = loadingRequest.contentInformationRequest, loadingRequest.dataRequest == nil {
            send(range: "bytes=0-1", for: loadingRequest) { [weak self] data, response in
                guard let self else { return }
                info.contentType = self.contentType
                info.isByteRangeAccessSupported = true
                info.contentLength = Self.totalLength(from: response) ?? Int64(data?.count ?? 0)
                loadingRequest.finishLoading()
            }
            return true
        }

        guard let dataRequest = loadingRequest.dataRequest else { return false }
        let offset = dataRequest.requestedOffset + Int64(dataRequest.currentOffset - dataRequest.requestedOffset)
        // `requestsAllDataToEndOfResource` has no end; everything else is a
        // closed range AVFoundation expects filled exactly.
        let header: String = if dataRequest.requestsAllDataToEndOfResource {
            "bytes=\(offset)-"
        } else {
            "bytes=\(offset)-\(offset + Int64(dataRequest.requestedLength) - 1)"
        }
        send(range: header, for: loadingRequest) { data, response in
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = self.contentType
                info.isByteRangeAccessSupported = true
                info.contentLength = Self.totalLength(from: response) ?? info.contentLength
            }
            if let data { dataRequest.respond(with: data) }
            loadingRequest.finishLoading()
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        queue.async {
            let key = ObjectIdentifier(loadingRequest)
            self.tasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func send(
        range: String,
        for loadingRequest: AVAssetResourceLoadingRequest,
        completion: @escaping (Data?, HTTPURLResponse?) -> Void
    ) {
        var request = URLRequest(url: origin)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let key = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { self.tasks.removeValue(forKey: key) }
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            completion(data, response as? HTTPURLResponse)
        }
        queue.async { self.tasks[key] = task }
        task.resume()
    }

    /// The total size out of `Content-Range: bytes 0-1/30655118`.
    static func totalLength(from response: HTTPURLResponse?) -> Int64? {
        guard let value = response?.value(forHTTPHeaderField: "Content-Range"),
              let total = value.split(separator: "/").last,
              let length = Int64(total) else { return nil }
        return length
    }
}
