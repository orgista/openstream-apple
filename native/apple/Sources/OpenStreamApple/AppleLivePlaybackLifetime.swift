import Foundation

/// Full-screen presentation covers the guide without ending its playback session.
@MainActor
final class AppleLivePlaybackLifetime {
    var isFullScreen = false
    private var loadIdentity: String?

    func beginLoad(identity: String) -> Bool {
        guard loadIdentity != identity else { return false }
        loadIdentity = identity
        return true
    }

    func inlineDisappeared(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        guard !isFullScreen else { return }
        stop(host: host, coordinator: coordinator)
    }

    func stop(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        loadIdentity = nil
        host.teardown()
        coordinator.stop()
    }
}
