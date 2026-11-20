import Foundation
import Network
import OpenStreamApple
import Testing

actor HealthProgressRecorder {
    var completed: [Int] = []
    func record(_ progress: AppleChannelHealthSweep.Progress) { completed.append(progress.completed) }
}

/// Loopback only. Each test owns and stops its listener, connections and callback tasks.
actor HealthHTTPFixture {
    private struct Route {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: Duration
        let bodyDelay: Duration
    }
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var counts: [String: Int] = [:]
    private var captured: [String: [String: String]] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Requests received and not yet answered.
    private var active = 0
    private(set) var maximumActive = 0
    private var holdsResponses = false
    private var heldResponses: [CheckedContinuation<Void, Never>] = []

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        do {
            let port = try await listener.startedPort(queue: DispatchQueue(label: "health-fixture.listener"))
            return URL(string: "http://127.0.0.1:\(port)")!
        } catch {
            await stop()
            throw error
        }
    }
    func route(_ path: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data(), delay: Duration = .zero, bodyDelay: Duration = .zero) {
        routes[path] = Route(status: status, headers: headers, body: body, delay: delay, bodyDelay: bodyDelay)
    }
    func hits(_ path: String) -> Int { counts[path, default: 0] }

    /// Received requests wait, unanswered, until `releaseResponses()`.
    func holdResponses() { holdsResponses = true }

    func releaseResponses() {
        holdsResponses = false
        heldResponses.forEach { $0.resume() }
        heldResponses = []
    }

    /// Returns once `count` requests are waiting for an answer.
    func waitForActive(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitFor("\(count) requests in flight", sourceLocation: sourceLocation) { active >= count }
    }

    /// Returns once `path` has been requested.
    func waitForHit(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitFor("a request for \(path)", sourceLocation: sourceLocation) { counts[path, default: 0] > 0 }
    }

    func header(_ path: String, _ name: String) -> String? { captured[path]?[name] }
    func stop() async {
        listener?.cancel()
        listener = nil
        releaseResponses()
        for task in tasks.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        let pending = Array(tasks.values)
        for task in pending { await task.value }
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        tasks[id] = Task { await serve(connection, id: id) }
    }
    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { connection.cancel(); connections[id] = nil; tasks[id] = nil }
        connection.start(queue: DispatchQueue(label: "health-fixture.connection"))
        do {
            var data = Data()
            while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                guard !chunk.isEmpty else { return }
                data.append(chunk)
            }
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            guard let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) else { return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            captured[path] = headers
            counts[path, default: 0] += 1
            active += 1
            maximumActive = max(active, maximumActive)
            let route = routes[path] ?? Route(status: 404, headers: [:], body: Data(), delay: .zero, bodyDelay: .zero)
            if holdsResponses { await withCheckedContinuation { heldResponses.append($0) } }
            do { try await Task.sleep(for: route.delay) } catch { active -= 1; throw error }
            // Answered from here on: a client that hears back can start its
            // next request before this connection's send completes.
            active -= 1
            var head = "HTTP/1.1 \(route.status) Fixture\r\nContent-Type: application/octet-stream\r\nContent-Length: \(route.body.count)\r\nConnection: close\r\n"
            for (key, value) in route.headers { head += "\(key): \(value)\r\n" }
            // Deliver a first body byte, then stall the remainder. Foundation does not
            // expose an HTTPURLResponse for a headers-only timed-out transfer on macOS.
            let prefixCount = route.bodyDelay > .zero ? min(1, route.body.count) : 0
            try await send(Data((head + "\r\n").utf8) + route.body.prefix(prefixCount), connection: connection)
            try await Task.sleep(for: route.bodyDelay)
            try await send(Data(route.body.dropFirst(prefixCount)), connection: connection)
        } catch { /* No request or error text is logged. */ }
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
    }
}

extension NWListener {
    /// Starts the listener and returns its port once it is ready.
    func startedPort(queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // Cleared on the first ready, failed or cancelled state, so it resumes once.
            stateUpdateHandler = { [unowned self] state in
                switch state {
                case .ready:
                    stateUpdateHandler = nil
                    if let port = port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error):
                    stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }
}
