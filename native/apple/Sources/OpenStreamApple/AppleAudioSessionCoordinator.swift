#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
import Foundation
#if os(iOS)
import AVKit
#endif

public enum AppleAudioRenderingMode: String, Equatable, Sendable {
    case notApplicable
    case monoStereo
    case surround
    case spatialAudio
    case dolbyAudio
    case dolbyAtmos
    case unknown
}

public struct AppleAudioOutputRoute: Equatable, Sendable {
    public let name: String
    public let portType: String
    public let channelCount: Int
    public let spatialAudioEnabled: Bool

    public init(name: String, portType: String, channelCount: Int, spatialAudioEnabled: Bool) {
        self.name = name
        self.portType = portType
        self.channelCount = channelCount
        self.spatialAudioEnabled = spatialAudioEnabled
    }
}

public struct AppleAudioRouteState: Equatable, Sendable {
    public let outputs: [AppleAudioOutputRoute]
    public let supportsMultichannelContent: Bool
    public let maximumOutputChannelCount: Int
    public let supportedOutputChannelCounts: [Int]
    public let spatialAudioEnabled: Bool
    public let renderingMode: AppleAudioRenderingMode
    public let lastRouteChangeReasonRawValue: UInt?
    public let isInterrupted: Bool

    public init(
        outputs: [AppleAudioOutputRoute],
        supportsMultichannelContent: Bool,
        maximumOutputChannelCount: Int,
        supportedOutputChannelCounts: [Int],
        spatialAudioEnabled: Bool,
        renderingMode: AppleAudioRenderingMode,
        lastRouteChangeReasonRawValue: UInt?,
        isInterrupted: Bool = false
    ) {
        self.outputs = outputs
        self.supportsMultichannelContent = supportsMultichannelContent
        self.maximumOutputChannelCount = maximumOutputChannelCount
        self.supportedOutputChannelCounts = supportedOutputChannelCounts
        self.spatialAudioEnabled = spatialAudioEnabled
        self.renderingMode = renderingMode
        self.lastRouteChangeReasonRawValue = lastRouteChangeReasonRawValue
        self.isInterrupted = isInterrupted
    }
}

public enum AppleAudioInterruptionEvent: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

#if os(iOS)
public enum ApplePreparedRouteSelection: String, Equatable, Sendable {
    case none
    case local
    case external
    case unknown
}

public struct AppleRoutePreparation: Equatable, Sendable {
    public let shouldStartPlayback: Bool
    public let selection: ApplePreparedRouteSelection

    public init(shouldStartPlayback: Bool, selection: ApplePreparedRouteSelection) {
        self.shouldStartPlayback = shouldStartPlayback
        self.selection = selection
    }
}
#endif

/// AVAudioSession is thread safe; only this wrapper crosses the serial worker.
private final class AppleAudioSessionAccess: @unchecked Sendable {
    let session: AVAudioSession
    init(session: AVAudioSession) { self.session = session }
    func prepare() throws {
        #if os(iOS)
        try session.setCategory(
            .playback,
            mode: .moviePlayback,
            policy: .longFormVideo,
            options: []
        )
        #else
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        #endif
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
        #if os(visionOS)
        // visionOS requires one exclusive candidate per process before the
        // session can publish system Now Playing information.
        _ = try? session.setIsNowPlayingCandidate(true)
        #endif
    }
    func activate() throws { try session.setActive(true) }
    func deactivate() throws {
        #if os(visionOS)
        _ = try? session.setIsNowPlayingCandidate(false)
        #endif
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Configures long-form movie playback while leaving route selection,
/// headphone personalization, head tracking, and Control Center overrides to
/// the system. State refreshes when routes or spatial capabilities change.
@MainActor
public final class AppleAudioSessionCoordinator: NSObject {
    public private(set) var state: AppleAudioRouteState
    public var onStateChange: (@MainActor @Sendable (AppleAudioRouteState) -> Void)?
    public var onInterruption: (@MainActor @Sendable (AppleAudioInterruptionEvent) -> Void)?
    /// Called when the output in use goes away, so whatever is playing can
    /// pause instead of moving to the device speaker. See
    /// `AppleAudioRoutePolicy`.
    public var outputDidDisappear: (@MainActor @Sendable () -> Void)?

    private let session: AVAudioSession
    private let access: AppleAudioSessionAccess

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        access = AppleAudioSessionAccess(session: session)
        state = Self.makeState(session: session, lastRouteChangeReasonRawValue: nil)
        super.init()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(routeDidChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(spatialCapabilitiesDidChange(_:)),
            name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: session
        )
        #if os(iOS) || os(tvOS)
        center.addObserver(
            self,
            selector: #selector(spatialCapabilitiesDidChange(_:)),
            name: AVAudioSession.renderingModeChangeNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(spatialCapabilitiesDidChange(_:)),
            name: AVAudioSession.renderingCapabilitiesChangeNotification,
            object: session
        )
        #endif
        center.addObserver(
            self,
            selector: #selector(mediaServicesWereReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(interruptionDidChange(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    /// Called on the main actor when the output in use goes away, so whatever
    /// is playing can pause itself. Set by the player host; nil elsewhere.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Configures and activates the shared session immediately before movie
    /// playback. iOS uses the long-form-video sharing policy so system route
    /// selection keeps audio and video together; tvOS manages that policy.
    public func prepareForPlayback() async throws {
        let access = access
        try await AppleAudioSessionWorkQueue.shared.perform { try access.prepare() }
        refreshState()
    }

    public func deactivate() {
        let access = access
        AppleAudioSessionWorkQueue.shared.enqueue { try? access.deactivate() }
    }

    #if os(iOS)
    public func prepareRouteSelectionForPlayback() async -> AppleRoutePreparation {
        await withCheckedContinuation { continuation in
            session.prepareRouteSelectionForPlayback { shouldStartPlayback, selection in
                continuation.resume(returning: AppleRoutePreparation(
                    shouldStartPlayback: shouldStartPlayback,
                    selection: Self.preparedSelection(selection)
                ))
            }
        }
    }
    #endif

    public func refreshState() {
        refreshState(lastRouteChangeReasonRawValue: state.lastRouteChangeReasonRawValue)
    }

    @objc
    nonisolated private func routeDidChange(_ notification: Notification) {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            refreshState(lastRouteChangeReasonRawValue: reason)
            // The reason used to be recorded and then ignored, so pulling
            // AirPods out moved the audio to the device speaker and kept
            // playing out loud. See `AppleAudioRoutePolicy`.
            if AppleAudioRoutePolicy.shouldPause(forRawValue: reason) {
                appleTrace("audio route lost — pausing")
                outputDidDisappear?()
            }
        }
    }

    @objc
    nonisolated private func spatialCapabilitiesDidChange(_: Notification) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    @objc
    nonisolated private func mediaServicesWereReset(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await prepareForPlayback()
            } catch {
                refreshState()
            }
        }
    }

    @objc
    nonisolated private func interruptionDidChange(_ notification: Notification) {
        guard let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                refreshState(isInterrupted: true)
                onInterruption?(.began)
            case .ended:
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                if shouldResume {
                    let access = access
                    try? await AppleAudioSessionWorkQueue.shared.perform { try access.activate() }
                }
                refreshState(isInterrupted: false)
                onInterruption?(.ended(shouldResume: shouldResume))
            @unknown default:
                refreshState()
            }
        }
    }

    private func refreshState(lastRouteChangeReasonRawValue: UInt?) {
        refreshState(
            lastRouteChangeReasonRawValue: lastRouteChangeReasonRawValue,
            isInterrupted: state.isInterrupted
        )
    }

    private func refreshState(isInterrupted: Bool) {
        refreshState(
            lastRouteChangeReasonRawValue: state.lastRouteChangeReasonRawValue,
            isInterrupted: isInterrupted
        )
    }

    private func refreshState(
        lastRouteChangeReasonRawValue: UInt?,
        isInterrupted: Bool
    ) {
        state = Self.makeState(
            session: session,
            lastRouteChangeReasonRawValue: lastRouteChangeReasonRawValue,
            isInterrupted: isInterrupted
        )
        onStateChange?(state)
    }

    private static func makeState(
        session: AVAudioSession,
        lastRouteChangeReasonRawValue: UInt?,
        isInterrupted: Bool = false
    ) -> AppleAudioRouteState {
        let outputs = session.currentRoute.outputs.map { output in
            AppleAudioOutputRoute(
                name: output.portName,
                portType: output.portType.rawValue,
                channelCount: output.channels?.count ?? 0,
                spatialAudioEnabled: output.isSpatialAudioEnabled
            )
        }
        #if os(visionOS)
        let supportedOutputChannelCounts: [Int] = []
        let renderingMode: AppleAudioRenderingMode = outputs.contains(where: \.spatialAudioEnabled)
            ? .spatialAudio
            : .notApplicable
        #else
        let supportedOutputChannelCounts = session.supportedOutputChannelLayouts
            .map { Int($0.channelCount) }
            .sorted()
        let renderingMode = renderingMode(session.renderingMode)
        #endif
        return AppleAudioRouteState(
            outputs: outputs,
            supportsMultichannelContent: session.supportsMultichannelContent,
            maximumOutputChannelCount: session.maximumOutputNumberOfChannels,
            supportedOutputChannelCounts: supportedOutputChannelCounts,
            spatialAudioEnabled: outputs.contains(where: \.spatialAudioEnabled),
            renderingMode: renderingMode,
            lastRouteChangeReasonRawValue: lastRouteChangeReasonRawValue,
            isInterrupted: isInterrupted
        )
    }

    #if os(iOS) || os(tvOS)
    private static func renderingMode(_ value: AVAudioSession.RenderingMode) -> AppleAudioRenderingMode {
        switch value {
        case .notApplicable: .notApplicable
        case .monoStereo: .monoStereo
        case .surround: .surround
        case .spatialAudio: .spatialAudio
        case .dolbyAudio: .dolbyAudio
        case .dolbyAtmos: .dolbyAtmos
        @unknown default: .unknown
        }
    }
    #endif

    #if os(iOS)
    nonisolated private static func preparedSelection(
        _ value: AVAudioSession.RouteSelection
    ) -> ApplePreparedRouteSelection {
        switch value {
        case .none: .none
        case .local: .local
        case .external: .external
        @unknown default: .unknown
        }
    }
    #endif
}
#else
import Foundation

// macOS stub — AVAudioSession is unavailable; the host uses these no-op
// types so ApplePlayerHost compiles uniformly across platforms.
@MainActor
public final class AppleAudioSessionCoordinator {
    public init(session: Any? = nil) {}
    public var onInterruption: (@MainActor @Sendable (AppleAudioInterruptionEvent) -> Void)?
    /// Never fires here: macOS has no `AVAudioSession`, so there is no route
    /// change to react to. Declared so `ApplePlayerHost` compiles uniformly,
    /// which is the whole point of this stub.
    public var outputDidDisappear: (@MainActor @Sendable () -> Void)?
    public func prepareForPlayback() async throws {}
    public func deactivate() {}
}

public enum AppleAudioInterruptionEvent: Sendable {
    case began
    case ended(shouldResume: Bool)
}
#endif
