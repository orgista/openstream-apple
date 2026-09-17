import Foundation

enum AppleBoundedHTTPError: Swift.Error, Equatable, Sendable {
    case responseTooLarge
}

enum AppleHTTPRedirectPolicy: Sendable {
    case follow
    case reject
    case secureHTTPOnly
}

/// Reusable control-plane HTTP client that receives Foundation's native data
/// chunks, caps every in-memory response, and applies a per-request redirect
/// policy. This avoids both byte-at-a-time `AsyncBytes` accumulation and a new
/// URLSession/TCP pool for every manifest, catalog, guide, or service request.
enum AppleBoundedHTTPDataLoader {
    private static let client = AppleBoundedHTTPClient()

    static func load(
        _ request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: AppleHTTPRedirectPolicy = .follow
    ) async throws -> (Data, URLResponse) {
        try await client.load(
            request,
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy,
            behavior: .rejectOverflow
        )
    }

    /// Returns at most `maximumBytes` and cancels the remaining transfer. Used
    /// only for media probes where the prefix is the complete desired result.
    static func loadPrefix(
        _ request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: AppleHTTPRedirectPolicy = .follow
    ) async throws -> (Data, URLResponse) {
        try await client.load(
            request,
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy,
            behavior: .returnPrefix
        )
    }
}

final class AppleBoundedHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Behavior: Equatable, Sendable {
        case rejectOverflow
        case returnPrefix
    }

    private final class RequestState: @unchecked Sendable {
        let maximumBytes: Int
        let redirectPolicy: AppleHTTPRedirectPolicy
        let behavior: Behavior
        let continuation: CheckedContinuation<(Data, URLResponse), any Swift.Error>
        var data = Data()
        var response: URLResponse?

        init(
            maximumBytes: Int,
            redirectPolicy: AppleHTTPRedirectPolicy,
            behavior: Behavior,
            continuation: CheckedContinuation<(Data, URLResponse), any Swift.Error>
        ) {
            self.maximumBytes = maximumBytes
            self.redirectPolicy = redirectPolicy
            self.behavior = behavior
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: Self.defaultConfiguration(), delegate: self, delegateQueue: nil)
    }

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    func load(
        _ request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: AppleHTTPRedirectPolicy,
        behavior: Behavior
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw AppleBoundedHTTPError.responseTooLarge }
        let taskBox = AppleBoundedHTTPTaskBox()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = RequestState(
                    maximumBytes: maximumBytes,
                    redirectPolicy: redirectPolicy,
                    behavior: behavior,
                    continuation: continuation
                )
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()
                taskBox.assign(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var oversized: RequestState?
        lock.lock()
        if let state = states[dataTask.taskIdentifier] {
            if state.behavior == .rejectOverflow,
               response.expectedContentLength > Int64(state.maximumBytes) {
                oversized = states.removeValue(forKey: dataTask.taskIdentifier)
            } else {
                state.response = response
                if response.expectedContentLength > 0 {
                    state.data.reserveCapacity(min(Int(response.expectedContentLength), state.maximumBytes))
                }
            }
        }
        lock.unlock()

        guard let oversized else {
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        oversized.continuation.resume(throwing: AppleBoundedHTTPError.responseTooLarge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var completed: (RequestState, Result<(Data, URLResponse), any Swift.Error>)?
        lock.lock()
        if let state = states[dataTask.taskIdentifier] {
            switch state.behavior {
            case .rejectOverflow:
                if data.count > state.maximumBytes - state.data.count {
                    _ = states.removeValue(forKey: dataTask.taskIdentifier)
                    completed = (state, .failure(AppleBoundedHTTPError.responseTooLarge))
                } else {
                    state.data.append(data)
                }
            case .returnPrefix:
                let remaining = state.maximumBytes - state.data.count
                if remaining > 0 { state.data.append(data.prefix(remaining)) }
                if state.data.count == state.maximumBytes, let response = state.response {
                    _ = states.removeValue(forKey: dataTask.taskIdentifier)
                    completed = (state, .success((state.data, response)))
                }
            }
        }
        lock.unlock()

        guard let completed else { return }
        dataTask.cancel()
        completed.0.continuation.resume(with: completed.1)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Swift.Error)?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let error {
            if (error as? URLError)?.code == .cancelled {
                state.continuation.resume(throwing: CancellationError())
            } else {
                state.continuation.resume(throwing: error)
            }
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let policy = states[task.taskIdentifier]?.redirectPolicy
        lock.unlock()

        switch policy {
        case .follow:
            completionHandler(request)
        case .reject, .none:
            completionHandler(nil)
        case .secureHTTPOnly:
            guard let components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

private final class AppleBoundedHTTPTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func assign(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
