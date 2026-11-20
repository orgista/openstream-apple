import Foundation

/// The app's one view of channel health: the persisted history read once, the
/// lineup the Live tab is showing, and the sweep Settings starts.
///
/// Rows never read `results` directly. The Live tab rebuilds a small map for
/// its own lineup when `revision` moves (`AppleChannelHealthMap`), so a guide
/// of 300 rows does no per-render lookups and no disk reads.
@MainActor
@Observable
public final class AppleChannelHealthStore {
    public static let shared = AppleChannelHealthStore()

    public struct Progress: Equatable, Sendable {
        public let completed: Int
        public let total: Int
    }

    /// Latest result per channel, keyed by `AppleChannelHealthResult.storageID`.
    public private(set) var results: [String: AppleChannelHealthResult] = [:]
    /// Moves when `results` changes in a way rows should redraw for.
    public private(set) var revision = 0
    /// The Live tab's All lineup: what the summary counts, the sweep checks
    /// and the export writes.
    public private(set) var lineup: [AppleIPTVChannel] = []
    public private(set) var progress: Progress?
    public private(set) var isPreparingLineup = false
    @ObservationIgnored private let lineupGate = AppleReloadGate()
    public var isSweeping: Bool { progress != nil }

    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    private struct LivePlayer { weak var coordinator: ApplePlaybackCoordinator? }
    private var livePlayers: [ObjectIdentifier: LivePlayer] = [:]
    public var hasLivePlayback: Bool { livePlayers.values.contains { $0.coordinator != nil } }

    func tracksLivePlayback(_ coordinator: ApplePlaybackCoordinator) -> Bool {
        livePlayers[ObjectIdentifier(coordinator)]?.coordinator != nil
    }

    func beginLivePlayback(_ coordinator: ApplePlaybackCoordinator) {
        livePlayers = livePlayers.filter { $0.value.coordinator != nil }
        livePlayers[ObjectIdentifier(coordinator)] = LivePlayer(coordinator: coordinator)
        cancelSweep()
    }

    func endLivePlayback(_ coordinator: ApplePlaybackCoordinator) {
        livePlayers[ObjectIdentifier(coordinator)] = nil
    }
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private let history: AppleChannelHealthHistory
    /// A review-build fixture: never reads or writes history, never probes.
    @ObservationIgnored let isFixture: Bool
    /// Review builds: open the detail for the first marked channel once.
    @ObservationIgnored private var wantsDebugDetail = false

    public init(history: AppleChannelHealthHistory = .shared) {
        self.history = history
        #if DEBUG
        let mode = UserDefaults.standard.string(forKey: AppleChannelHealthFixture.launchKey)
        isFixture = mode == "fixture" || mode == "detail"
        wantsDebugDetail = mode == "detail"
        #else
        isFixture = false
        #endif
    }

    /// Reads the persisted history once per launch.
    public func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        guard !isFixture else { return }
        let snapshot = await history.snapshot()
        var loaded = snapshot.mapValues(\.lastResult)
        // A sweep that finished while the read was in flight is newer.
        loaded.merge(results) { _, current in current }
        results = loaded
        revision &+= 1
    }

    public func setLineup(_ channels: [AppleIPTVChannel]) {
        guard channels.map(\.id) != lineup.map(\.id) else { return }
        lineup = channels
        #if DEBUG
        if isFixture {
            results = AppleChannelHealthFixture.results(for: channels, now: .now)
            revision &+= 1
        }
        #endif
    }

    /// Settings reads saved channels; the health page and explicit checks may fetch a missing lineup.
    public func prepareLineupIfNeeded(settings: AppleSettingsStore, sourceStore: AppleSourceStore,
                                     allowsNetwork: Bool = false,
                                     cache: AppleIPTVChannelCache = .shared,
                                     client: AppleIPTVClient = AppleIPTVClient()) async {
        guard !Task.isCancelled, await lineupGate.waitUntilIdle(), lineup.isEmpty, lineupGate.begin() else { return }
        isPreparingLineup = true
        defer {
            isPreparingLineup = false
            lineupGate.end()
        }
        var cached: [AppleIPTVChannel] = []
        for source in sourceStore.sources where source.kind == .liveTV && source.isEnabled {
            guard !Task.isCancelled else { return }
            if let snapshot = await cache.snapshot(for: source.id), !snapshot.channels.isEmpty {
                cached.append(contentsOf: snapshot.channels)
                continue
            }
            guard allowsNetwork else { continue }
            do {
                let channels = try await client.channels(source: source, credentials: sourceStore.iptvCredentials(for: source))
                guard !Task.isCancelled else { return }
                let sourceChannels = await cache.reconcileAndStore(channels, for: source.id)
                cached.append(contentsOf: sourceChannels)
                sourceStore.recordValidationSuccess(id: source.id, summary: "Connected · \(sourceChannels.count) channels",
                    discoveredItemCount: sourceChannels.count, capabilities: ["Live channels", "Playback"])
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                sourceStore.recordValidationFailure(id: source.id,
                    summary: AppleIPTVFailureCause.message(for: error, providerName: source.name))
            }
        }
        guard !Task.isCancelled else { return }
        settings.updateAutomaticLiveChannelPackage(channels: cached)
        guard !cached.isEmpty else { return }
        let groups = await AppleChannelProjection.buildGroupsOffMain(
            from: cached,
            scope: settings.liveChannelScope,
            showPayPerView: settings.showPayPerViewChannels,
            favoriteIDs: settings.favoriteChannelIDs,
            query: "",
            regionalZIPCode: settings.regionalZIPCode,
            show24x7: settings.liveChannelPackage == .custom || settings.show24x7Channels
        )
        let package = settings.liveChannelPackage
        let custom = settings.customChannelPackage
        let favorites = settings.favoriteChannelIDs
        let snapshot = await Task.detached(priority: .userInitiated) {
            AppleLiveChannelSnapshot.build(groups: groups, package: package, custom: custom,
                entries: AppleChannelLineupPresets.current,
                favoriteIDs: favorites, category: "All")
        }.value
        guard !Task.isCancelled, lineup.isEmpty else { return }
        setLineup(snapshot.channels)
    }

    /// The first marked channel of `channels`, once per launch, when the
    /// review fixture asked for its detail to open.
    func takeDebugDetailChannel(from channels: [AppleIPTVChannel]) -> AppleIPTVChannel? {
        guard wantsDebugDetail else { return nil }
        let map = map(for: channels)
        guard let channel = channels.first(where: { AppleChannelHealthIndicator(result: map[$0.id]) != nil }) else { return nil }
        wantsDebugDetail = false
        return channel
    }

    public func map(for channels: [AppleIPTVChannel]) -> [String: AppleChannelHealthResult] {
        AppleChannelHealthMap.build(channels: channels, results: results)
    }

    public func summary(now: Date) -> String {
        AppleChannelHealthSummary.line(lineupIDs: lineup.map(\.id), results: results, now: now)
    }

    public var workingCount: Int {
        lineup.filter { results[AppleChannelHealthResult.storageID($0.id)]?.bucket == .online }.count
    }

    /// Runs the phase-1 sweep with its defaults over the current lineup.
    public func startSweep() {
        startSweep(channels: lineup)
    }

    /// One channel, from its detail.
    public func recheck(_ channel: AppleIPTVChannel) {
        startSweep(channels: [channel])
    }

    public func cancelSweep() {
        sweepTask?.cancel()
    }

    /// Reset OpenStream: the history on disk is gone, so is this copy.
    func discardAfterReset() {
        sweepTask?.cancel()
        results = [:]
        lineup = []
        didLoad = false
        revision &+= 1
    }

    private func startSweep(channels: [AppleIPTVChannel]) {
        guard sweepTask == nil, !channels.isEmpty, !isFixture, !hasLivePlayback else { return }
        let history = history
        progress = Progress(completed: 0, total: channels.count)
        // Holds the store until the sweep ends or is cancelled.
        sweepTask = Task {
            _ = try? await AppleChannelHealthSweep().run(channels, history: history) { step in
                await self.apply(step)
            }
            finishSweep()
        }
    }

    private func apply(_ step: AppleChannelHealthSweep.Progress) {
        results[step.result.channelID] = step.result
        progress = Progress(completed: step.completed, total: step.total)
        // Rows redraw in batches while a long sweep runs, not per channel.
        if step.completed % 10 == 0 || step.completed == step.total { revision &+= 1 }
    }

    private func finishSweep() {
        sweepTask = nil
        progress = nil
        revision &+= 1
    }
}
