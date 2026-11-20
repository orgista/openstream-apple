import Observation
import AetherEngine

/// Observable navigation state, mirrored from the engine's publisher.
@MainActor @Observable
public final class AppleDiscMenuSession {
    public internal(set) var state: DVDMenuState?
    public init() {}
}
