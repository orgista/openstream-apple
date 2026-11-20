import Foundation
import Synchronization

/// The connection pool every media-server API request goes through, which a
/// stalled request replaces.
///
/// Walk b20r24 (owner iPhone, 2026-11-07): in one launch every Rill request
/// went unanswered (a trailer lookup hit its 15 s limit, the hero title's item
/// lookup was still open after 33 s), so the hero's Play opened the page and
/// never played. The next launches, on new connections, answered in 0.2 s.
/// After a request gets no answer, later requests and the retry use a new
/// pool instead of queueing on the stuck connection again.
final class AppleMediaServerConnection: Sendable {
    static let shared = AppleMediaServerConnection()

    private struct Pool {
        var session: URLSession
        var generation: Int
    }
    private let pool: Mutex<Pool>
    private let makeSession: @Sendable () -> URLSession

    init(makeSession: @escaping @Sendable () -> URLSession = { URLSession(configuration: .default) }) {
        self.makeSession = makeSession
        pool = Mutex(Pool(session: makeSession(), generation: 0))
    }

    var generation: Int { pool.withLock { $0.generation } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await pool.withLock { $0.session }.data(for: request)
    }

    /// Opens a new pool unless one was already opened since `generation`:
    /// several requests stuck on the same connection replace it once.
    func replace(after generation: Int) {
        let stale: URLSession? = pool.withLock { pool in
            guard pool.generation == generation else { return nil }
            let old = pool.session
            pool = Pool(session: makeSession(), generation: generation + 1)
            return old
        }
        guard let stale else { return }
        appleTrace("media server connection replaced after a request got no answer")
        stale.finishTasksAndInvalidate()
    }
}
