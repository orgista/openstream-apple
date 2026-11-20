import CoreGraphics
import Foundation
import Network
import Observation
import Synchronization

/// Warm a bounded first window through the same image and guide caches the views use.
@MainActor
enum AppleLivePrefetch {
    // Two screens: ten compact guide rows on TV, eight list rows on iOS, twelve elsewhere.
    nonisolated static let leadingCount: Int = {
        #if os(tvOS)
        20
        #elseif os(iOS)
        16
        #else
        24
        #endif
    }()

    /// Logos loaded at once, and how long the prefetch waits for them. A
    /// healthy logo arrives in 70-250 ms (test Apple TV walk 8); a slower one keeps
    /// loading after the deadline and is cached for the rows.
    nonisolated static let logoWidth = 6
    nonisolated static let logoDeadline: Duration = .seconds(2)
    /// Long enough for a dead host's 15 s request timeout in each of three
    /// rounds of six.
    nonisolated static let logoSettleWait: Duration = .seconds(60)

    static func run(sourceStore: AppleSourceStore, settings: AppleSettingsStore, displayScale: CGFloat) async {
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        guard settings.liveTVEnabled, !sources.isEmpty else { return }
        do { try await Task.sleep(for: AppleLaunchWorkPolicy.remainingLaunchWindow(processAge: AppleLaunchMarks.launchAge())) }
        catch { return }
        guard AppleLivePrefetchNetwork.shared.allowsPrefetch else {
            appleTrace("live prefetch skipped: cellular or Low Data Mode")
            return
        }
        let preferred = AppleLiveWatchHistoryStore.shared.history.channelIDs + settings.favoriteLiveChannelOrder
            + settings.favoriteChannelIDs.sorted()
        let hidden = settings.hiddenLiveChannelIDs
        let entries = AppleChannelLineupPresets.current
        var lineups: [UUID: [AppleIPTVChannel]] = [:]
        var requests: [PlaylistRequest] = []
        for source in sources {
            let saved = await AppleIPTVChannelCache.shared.snapshot(for: source.id)
            lineups[source.id] = saved?.channels ?? []
            if saved == nil || saved?.isStale() == true {
                requests.append(PlaylistRequest(source: source, credentials: try? sourceStore.iptvCredentials(for: source)))
            }
        }
        let cachedLeading = leadingChannels(sources.flatMap { lineups[$0.id] ?? [] },
            preferredIDs: preferred, hiddenIDs: hidden, entries: entries)
        let guide = AppleIPTVGuideStore()
        async let cachedWarm: Void = warm(cachedLeading, sources: sources, sourceStore: sourceStore,
            settings: settings, displayScale: displayScale, guide: guide)
        await withTaskGroup(of: (UUID, [AppleIPTVChannel]?).self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let received = try await AppleLivePlaylistFetches.shared.channels(source: request.source,
                            credentials: request.credentials, client: AppleIPTVClient())
                        guard !Task.isCancelled else { return (request.source.id, nil) }
                        let channels = await AppleIPTVChannelCache.shared.reconcileAndStore(received, for: request.source.id)
                        return (request.source.id, channels)
                    } catch {
                        if !Task.isCancelled { appleTrace("live prefetch playlist unavailable") }
                        return (request.source.id, nil)
                    }
                }
            }
            for await (sourceID, channels) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                guard let channels else { continue }
                lineups[sourceID] = channels
                let leading = leadingChannels(sources.flatMap { lineups[$0.id] ?? [] },
                    preferredIDs: preferred, hiddenIDs: hidden, entries: entries)
                await warm(leading, sources: sources, sourceStore: sourceStore, settings: settings, displayScale: displayScale, guide: guide)
            }
        }
        await cachedWarm
    }

    static func warm(_ channels: [AppleIPTVChannel], sources: [AppleSource], sourceStore: AppleSourceStore,
                     settings: AppleSettingsStore, displayScale: CGFloat, guide: AppleIPTVGuideStore) async {
        guard !channels.isEmpty, !Task.isCancelled, AppleLivePrefetchNetwork.shared.allowsPrefetch else { return }
        let started = ContinuousClock.now
        let requests = logoRequests(channels, displayScale: displayScale)
        async let logos = AppleRemoteImageCache.shared.warm(requests, width: logoWidth, deadline: logoDeadline)
        guide.configure(liveSources: sources, channels: channels, sourceStore: sourceStore, settings: settings)
        await guide.refreshVisible(channelIDs: Set(channels.map(\.id)))
        let ready = await logos
        let total = Set(requests).count
        appleTrace("live prefetch channels=\(channels.count) logos=\(ready)/\(total) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
        guard ready < total else { return }
        Task.detached(priority: .utility) {
            let settled = await AppleRemoteImageCache.shared.warm(requests, width: logoWidth, deadline: logoSettleWait)
            appleTrace("live logos settled logos=\(settled)/\(total) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
        }
    }

    struct PlaylistRequest: Sendable {
        let source: AppleSource
        let credentials: AppleIPTVCredentials?
    }

    /// The channels Live is likely to draw first: the ones watched and
    /// favourited, then the imported lineup's numbers when there is one (the
    /// order Live sorts by), then the playlists' own order, skipping hidden ones.
    nonisolated static func leadingChannels(_ channels: [AppleIPTVChannel], preferredIDs: [String],
                                            hiddenIDs: Set<String>, entries: [AppleChannelLineupEntry] = [],
                                            limit: Int = leadingCount) -> [AppleIPTVChannel] {
        var visible = channels.filter { !hiddenIDs.contains($0.id) }
        if !entries.isEmpty {
            let index = AppleChannelLineupIndex(entries)
            visible = visible.enumerated()
                .map { (number: index.match($0.element.name)?.number ?? .max, offset: $0.offset, channel: $0.element) }
                .sorted { ($0.number, $0.offset) < ($1.number, $1.offset) }
                .map(\.channel)
        }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [AppleIPTVChannel] = []
        for channel in preferredIDs.compactMap({ byID[$0] }) + visible {
            guard result.count < limit else { break }
            if seen.insert(channel.id).inserted { result.append(channel) }
        }
        return result
    }

    /// Logos at the size this platform's Live rows decode them, so the warm
    /// entry is the one they ask for (`AppleRemoteImageCache` keys by size).
    nonisolated static func logoRequests(_ channels: [AppleIPTVChannel],
                                         displayScale: CGFloat) -> [AppleArtworkPrefetchPolicy.Request] {
        let pixels = AppleArtworkSizePolicy.bucket(size: rowLogoSize, scale: displayScale)
        return channels.compactMap(\.logoURL).map {
            AppleArtworkPrefetchPolicy.Request(url: $0, maximumPixelDimension: pixels)
        }
    }

    /// The logo frame of a Live channel row here: the Paramount+ row on
    /// iPhone and iPad, the guide rail's tile less its 6 pt padding on Apple
    /// TV (`AppleTVGuideLogoTile`), the plain row elsewhere (`AppleLiveOnNowRow`).
    nonisolated static var rowLogoSize: CGSize {
        #if os(tvOS)
        let tile = AppleTVGuideMetrics.standard.logoSize
        return CGSize(width: tile.width - 12, height: tile.height - 12)
        #elseif os(iOS)
        return AppleLiveStagePolicy.phoneLogoSize
        #else
        return CGSize(width: 48, height: 32)
        #endif
    }
}

@MainActor
@Observable
final class AppleLivePrefetchNetwork {
    static let shared = AppleLivePrefetchNetwork()
    private(set) var allowsPrefetch = true
    @ObservationIgnored private let monitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSequence = 0

    init(monitor: NWPathMonitor? = NWPathMonitor()) {
        self.monitor = monitor
        guard let monitor else { return }
        let sequence = Mutex(0)
        monitor.pathUpdateHandler = { [weak self] path in
            let update = sequence.withLock { $0 += 1; return $0 }
            let allowed = Self.permits(status: path.status, isExpensive: path.isExpensive,
                isConstrained: path.isConstrained)
            Task { @MainActor [weak self] in self?.applyPath(allowsPrefetch: allowed, sequence: update) }
        }
        monitor.start(queue: DispatchQueue(label: "com.orgista.openstream.live-prefetch-network"))
    }

    func applyPath(allowsPrefetch: Bool, sequence: Int) {
        guard sequence > lastPathSequence else { return }
        lastPathSequence = sequence
        self.allowsPrefetch = allowsPrefetch
    }

    nonisolated static func permits(status: NWPath.Status?, isExpensive: Bool = false,
                                   isConstrained: Bool = false) -> Bool {
        guard let status else { return true }
        return status == .satisfied && !isExpensive && !isConstrained
    }
}

/// One download per playlist at a time: Live opened while the launch
/// prefetch is still fetching waits for that download instead of starting a
/// second one, and the other way round.
actor AppleLivePlaylistFetches {
    static let shared = AppleLivePlaylistFetches()
    private var inFlight: [String: Task<[AppleIPTVChannel], any Error>] = [:]

    func channels(source: AppleSource, credentials: AppleIPTVCredentials?,
                  client: AppleIPTVClient) async throws -> [AppleIPTVChannel] {
        let key = "\(source.id.uuidString)|\(source.configurationRevision)"
        if let running = inFlight[key] { return try await running.value }
        let download = Task { try await client.channels(source: source, credentials: credentials) }
        inFlight[key] = download
        defer { inFlight[key] = nil }
        let started = ContinuousClock.now
        let channels = try await download.value
        AppleLaunchMarks.record(.livePlaylistParsed, "channels=\(channels.count)")
        appleTrace("live playlist parsed channels=\(channels.count) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
        return channels
    }
}
