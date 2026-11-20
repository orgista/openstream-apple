import Foundation

actor AppleIPTVAccountLimits {
    static let shared = AppleIPTVAccountLimits(defaults: .standard)

    private var limits: [UUID: Int] = [:]
    private let defaults: UserDefaults?
    private let client: AppleIPTVClient
    private weak var sourceStore: AppleSourceStore?
    private static let storageKey = "openstream.iptv.maxConnections.v1"
    /// The owner's one-slot panel serves a second stream while it still counts
    /// the old one (followups-1107) and frees it 0.1–1.8 s later; an explicit
    /// limit refusal re-waits through the coordinator's one retry.
    private static let closeTimeout: Duration = .seconds(1)
    private static let closePollInterval: Duration = .milliseconds(100)

    init(defaults: UserDefaults? = nil, client: AppleIPTVClient = AppleIPTVClient()) {
        self.defaults = defaults
        self.client = client
        for (key, value) in defaults?.dictionary(forKey: Self.storageKey) ?? [:] {
            if let sourceID = UUID(uuidString: key), let maximum = value as? Int, maximum >= 0 {
                limits[sourceID] = maximum
            }
        }
    }

    /// Also forgets the limits of sources that are no longer in `sourceIDs`.
    func registerSourceStore(_ sourceStore: AppleSourceStore, sourceIDs: Set<UUID>) {
        self.sourceStore = sourceStore
        let kept = limits.filter { sourceIDs.contains($0.key) }
        if kept.count != limits.count {
            limits = kept
            persist()
        }
    }

    func record(_ info: AppleIPTVAccountInfo, sourceID: UUID) {
        if let maximum = info.maxConnections, limits[sourceID] != maximum {
            limits[sourceID] = maximum
            persist()
        }
    }

    private func persist() {
        defaults?.set(Dictionary(uniqueKeysWithValues: limits.map { ($0.key.uuidString, $0.value) }), forKey: Self.storageKey)
    }

    func snapshot() -> [UUID: Int] { limits }

    /// Aether stops its pump asynchronously. Wait briefly for the panel to
    /// acknowledge closure; stale or unavailable counts must not veto a stream.
    func waitForAvailableConnection(sourceID: UUID?, clock: any AppleClock = AppleSystemClock()) async throws {
        guard let sourceID, limits[sourceID] == 1 else { return }
        guard let stoppedAt = await AppleIPTVPreviewActivity.shared.lastStoppedAt(sourceID: sourceID) else { return }
        let deadline = min(clock.now.advanced(by: Self.closeTimeout), stoppedAt.advanced(by: Self.closeTimeout))
        guard clock.now < deadline else { return }
        guard let store = sourceStore else { return }
        let account = await MainActor.run { () -> (AppleSource, AppleIPTVCredentials)? in
            guard let source = store.sources.first(where: { $0.id == sourceID && $0.isEnabled }),
                  let credentials = try? store.iptvCredentials(for: source) else { return nil }
            return (source, credentials)
        }
        try Task.checkCancellation()
        guard let (source, credentials) = account else { return }
        // The wait sits before the stream request, so a slow switch shows it here (walk 8: 1.95 s).
        let waitStarted = clock.now
        var polls = 0
        var outcome = "deadline"
        defer {
            appleTrace("iptv slot wait \(outcome) polls=\(polls) ms=\(AppleLaunchMarks.milliseconds(waitStarted.duration(to: clock.now)))")
        }
        while clock.now < deadline {
            try Task.checkCancellation()
            polls += 1
            do {
                let remaining = clock.now.duration(to: deadline) / .seconds(1)
                let info = try await client.accountInfo(source: source, credentials: credentials,
                    timeout: max(Self.closePollInterval / .seconds(1), remaining))
                try Task.checkCancellation()
                record(info, sourceID: sourceID)
                guard info.rejection() == "MaxConnections" else {
                    outcome = "free"
                    return
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                guard AppleIPTVFailureCause.classify(error) == .streamLimit else {
                    outcome = "unknown"
                    return
                }
            }
            guard clock.now < deadline else { return }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: Self.closePollInterval)))
        }
    }
}

@MainActor
final class AppleIPTVPreviewActivity {
    static let shared = AppleIPTVPreviewActivity()
    private struct Stream {
        weak var owner: AnyObject?
        let sourceID: UUID
    }
    private var streams: [ObjectIdentifier: Stream] = [:]
    private var stoppedAt: [UUID: ContinuousClock.Instant] = [:]
    private static let closeGrace: Duration = .seconds(2)

    func began(_ owner: AnyObject, sourceID: UUID) {
        streams = streams.filter { $0.value.owner != nil }
        streams[ObjectIdentifier(owner)] = Stream(owner: owner, sourceID: sourceID)
    }

    func ended(_ owner: AnyObject, now: ContinuousClock.Instant = .now) {
        guard let stream = streams.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        stoppedAt[stream.sourceID] = now
    }

    func isActiveOrRecent(sourceID: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        streams.values.contains { $0.owner != nil && $0.sourceID == sourceID }
            || stoppedAt[sourceID].map { $0.duration(to: now) < Self.closeGrace } == true
    }

    func lastStoppedAt(sourceID: UUID) -> ContinuousClock.Instant? { stoppedAt[sourceID] }

    func allowsAutomaticPreview(sourceID: UUID, maximumConnections: Int?, now: ContinuousClock.Instant = .now) -> Bool {
        maximumConnections != 1 || !isActiveOrRecent(sourceID: sourceID, now: now)
    }
}

public struct AppleIPTVAccountInfo: Equatable, Sendable {
    public let expiresAt: Date?
    public let maxConnections: Int?
    public let activeConnections: Int?
    public let status: String?

    public init(expiration: String?, maxConnections: String?, activeConnections: String?, status: String?) {
        expiresAt = expiration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.maxConnections = maxConnections.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        self.activeConnections = activeConnections.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        self.status = status
    }

    public var streamsInUse: String? {
        guard let activeConnections, let maxConnections, maxConnections > 0 else { return nil }
        return "\(activeConnections) of \(maxConnections) streams in use"
    }

    public func rejection(now: Date = .now, checkConnections: Bool = true) -> String? {
        let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["expired", "disabled", "banned"].contains(normalized) { return status }
        if let expiresAt, expiresAt <= now { return "Expired" }
        if checkConnections, let maximum = maxConnections, maximum > 0,
           let active = activeConnections, active >= maximum { return "MaxConnections" }
        return nil
    }
}
