import Foundation
import Observation

/// Full-screen presentation covers the guide without ending its playback session.
@MainActor
@Observable
final class AppleLivePlaybackLifetime {
    typealias Resources = (host: ApplePlayerHost, audioSession: AppleAudioSessionCoordinator)

    @ObservationIgnored var isFullScreen = false
    @ObservationIgnored private var loadIdentity: String?
    @ObservationIgnored private(set) var isInBackground = false
    @ObservationIgnored private let makeResources: @MainActor (ApplePlaybackCoordinator) -> Resources
    private var ownedResources: (coordinator: ApplePlaybackCoordinator, resources: Resources)?

    init(makeResources: @escaping @MainActor (ApplePlaybackCoordinator) -> Resources = { coordinator in
        let audioSession = AppleAudioSessionCoordinator()
        return (host: ApplePlayerHost(coordinator: coordinator, audioSession: audioSession,
            activateImmediately: false), audioSession: audioSession)
    }) {
        self.makeResources = makeResources
    }

    func resources(for coordinator: ApplePlaybackCoordinator) -> Resources? {
        guard let ownedResources, ownedResources.coordinator === coordinator else { return nil }
        return ownedResources.resources
    }

    func configure(for coordinator: ApplePlaybackCoordinator) {
        guard ownedResources?.coordinator !== coordinator else { return }
        if let ownedResources {
            stop(host: ownedResources.resources.host, coordinator: ownedResources.coordinator)
        }
        ownedResources = (coordinator: coordinator, resources: makeResources(coordinator))
        AppleInteractionTrace.record(.playback, "live inline configured")
    }

    func enteredBackground(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        isInBackground = true
        guard !host.keepsPlaybackForPictureInPicture else { return }
        stop(host: host, coordinator: coordinator)
    }

    func enteredForeground() { isInBackground = false }

    func beginLoad(identity: String) -> Bool {
        guard loadIdentity != identity else { return false }
        loadIdentity = identity
        return true
    }

    func inlineDisappeared(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator, isSearching: Bool = false) {
        AppleInteractionTrace.record(.playback, "live inline disappeared searching=\(isSearching)")
        guard !isSearching, !isFullScreen, !host.keepsPlaybackForPictureInPicture else { return }
        stop(host: host, coordinator: coordinator)
    }

    func stop(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        loadIdentity = nil
        host.teardown()
        coordinator.stop()
    }
}
