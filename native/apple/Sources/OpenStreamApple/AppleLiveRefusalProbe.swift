import Foundation

/// Asks a live channel's URL once for its HTTP status after the engine failed
/// to open it. The demuxer reports a provider's refusal as `open failed
/// (Input/output error (-5))`, so "ABC SPARK" (HTTP 403, empty `text/html`
/// body, walk b20r21) read as "isn't broadcasting". The probe reads only the
/// response head and cancels before the body, so it never holds a stream
/// open against the account's connection limit.
enum AppleLiveRefusalProbe {
    static let timeout: TimeInterval = 3

    /// The final status after redirects, or nil when there was no answer.
    @concurrent
    static func status(_ url: URL, headers: [String: String]) async -> Int? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.allHTTPHeaderFields = headers
        guard let (_, response) = try? await session.bytes(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// The refusal as the failure the viewer should see, or nil to keep the
    /// engine's own.
    static func refusal(status: Int?) -> ApplePlaybackFailure? {
        guard let status, status == 401 || status == 403 else { return nil }
        return ApplePlaybackFailure(kind: .authentication,
                                    message: "The provider refused this channel (HTTP \(status)).",
                                    httpStatus: status)
    }
}
