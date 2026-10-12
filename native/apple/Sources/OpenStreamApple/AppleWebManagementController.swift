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
    public private(set) var connectedBrowsers: [AppleWebManagementServer.ConnectedBrowser] = []
    public private(set) var error: String?
    public private(set) var isRunning = false

    public var running: Bool { isRunning }

    @ObservationIgnored private let configuration: AppleWebManagementServer.Configuration
    #if OPENSTREAM_ADDONS
    @ObservationIgnored private let manifestClient: AppleManifestClient
    #endif
    @ObservationIgnored private var server: AppleWebManagementServer?
    @ObservationIgnored private var sessionObservers: [
        UUID: AsyncStream<AppleWebManagementSession?>.Continuation
    ] = [:]

    public init() {
        configuration = .init()
        #if OPENSTREAM_ADDONS
        manifestClient = AppleManifestClient()
        #endif
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

#if OPENSTREAM_ADDONS
    init(
        configuration: AppleWebManagementServer.Configuration,
        manifestClient: AppleManifestClient
    ) {
        self.configuration = configuration
        self.manifestClient = manifestClient
    }
#else
    init(configuration: AppleWebManagementServer.Configuration) { self.configuration = configuration }
#endif

    @discardableResult
    public func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession {
        stopActiveServer(clearError: true)

#if OPENSTREAM_ADDONS
        let newServer = AppleWebManagementServer(
            configuration: configuration,
            manifestClient: manifestClient
        )
#else
        let newServer = AppleWebManagementServer(configuration: configuration)

#endif
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
        newServer.onSessionChange = { [weak self, weak newServer] updated in
            guard let self, let newServer, self.server === newServer else { return }
            self.session = updated
        }
        newServer.onBrowsersChange = { [weak self, weak newServer] browsers in
            guard let self, let newServer, self.server === newServer else { return }
            self.connectedBrowsers = browsers
            for observer in self.sessionObservers.values { observer.yield(self.session) }
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

    public func endBrowser(id: UUID) {
        server?.endBrowser(id: id)
    }

    public func endAllBrowsers() {
        server?.endAllBrowsers()
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
        connectedBrowsers = []
        isRunning = false
        if clearError { error = nil }
    }
}
