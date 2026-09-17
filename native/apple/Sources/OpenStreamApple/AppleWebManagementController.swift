import Foundation
import Observation

@MainActor
@Observable
public final class AppleWebManagementController: AppleWebManagementServing {
    public private(set) var session: AppleWebManagementSession? {
        didSet {
            for observer in sessionObservers.values { observer.yield(session) }
        }
    }
    public private(set) var error: String?
    public private(set) var isRunning = false

    public var running: Bool { isRunning }

    @ObservationIgnored private let configuration: AppleWebManagementServer.Configuration
    @ObservationIgnored private let manifestClient: AppleManifestClient
    @ObservationIgnored private var server: AppleWebManagementServer?
    @ObservationIgnored private var sessionObservers: [
        UUID: AsyncStream<AppleWebManagementSession?>.Continuation
    ] = [:]

    public init() {
        configuration = .init()
        manifestClient = AppleManifestClient()
    }

    public func sessionUpdates() -> AsyncStream<AppleWebManagementSession?> {
        let id = UUID()
        return AsyncStream { continuation in
            sessionObservers[id] = continuation
            continuation.yield(session)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.sessionObservers.removeValue(forKey: id)
                }
            }
        }
    }

    init(
        configuration: AppleWebManagementServer.Configuration,
        manifestClient: AppleManifestClient
    ) {
        self.configuration = configuration
        self.manifestClient = manifestClient
    }

    @discardableResult
    public func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession {
        stopActiveServer(clearError: true)

        let newServer = AppleWebManagementServer(
            configuration: configuration,
            manifestClient: manifestClient
        )
        newServer.onStop = { [weak self, weak newServer] reason in
            guard let self, let newServer, self.server === newServer else { return }
            self.server = nil
            self.session = nil
            self.isRunning = false
            switch reason {
            case .expired:
                self.error = "The Web Management session expired."
            case .failed(let message):
                self.error = message.isEmpty ? "Web Management stopped unexpectedly." : message
            case .completed, .stopped:
                self.error = nil
            }
        }
        server = newServer

        do {
            let activeSession = try await newServer.start(sourceStore: sourceStore)
            guard server === newServer else { throw CancellationError() }
            session = activeSession
            isRunning = true
            error = nil
            return activeSession
        } catch {
            if server === newServer {
                newServer.onStop = nil
                newServer.dispose()
                server = nil
                session = nil
                isRunning = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    public func stop() async {
        stopActiveServer(clearError: true)
    }

    public func dispose() async {
        await stop()
    }

    private func stopActiveServer(clearError: Bool) {
        let activeServer = server
        server = nil
        activeServer?.onStop = nil
        activeServer?.dispose()
        session = nil
        isRunning = false
        if clearError { error = nil }
    }
}
