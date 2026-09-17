import Foundation
import Observation

@MainActor
@Observable
public final class AppleIPTVGuideStore {
    private let loader: AppleIPTVGuideLoader

    private struct ChannelCache: Sendable {
        let programmes: [AppleIPTVProgramme]
        let fetchTime: Date
    }

    private enum Configuration: Equatable {
        case xmltv(URL, [String: String])
        case xtream(URL, String, String)
    }

    private var caches: [String: ChannelCache] = [:]
    private var configurations: [String: Configuration] = [:]
    private var inFlight = Set<String>()
    private let expiry: TimeInterval = 15 * 60

    /// Bumped whenever the programme caches change. Views key their derived
    /// work (the Apple TV grid model) on it instead of diffing the guide.
    public private(set) var revision = 0

    /// `guide(for:)` is called from view bodies, which re-run for reasons that
    /// have nothing to do with the guide; grouping and sorting every programme
    /// each time made the Apple TV Live tab crawl. The last answer is kept and
    /// reused while neither the channel list nor `revision` has moved. Ignored
    /// by observation so filling it during a body pass notifies nobody.
    @ObservationIgnored private var guideCache: (ids: [String], revision: Int, guide: AppleIPTVGuide)?

    public init(loader: AppleIPTVGuideLoader = AppleIPTVGuideLoader()) {
        self.loader = loader
    }

    public func configure(xmltvURL: URL?, sourceID: UUID? = nil, channelMapping: [String: String] = [:]) {
        setConfiguration(xmltvURL.map { .xmltv($0, channelMapping) }, key: sourceID?.uuidString ?? "")
    }

    public func configure(xtreamBase: URL, username: String, password: String, sourceID: UUID? = nil) {
        setConfiguration(.xtream(xtreamBase, username, password), key: sourceID?.uuidString ?? "")
    }

    private func setConfiguration(_ value: Configuration?, key: String) {
        guard configurations[key] != value else { return }
        configurations[key] = value
        caches = caches.filter { cacheKey, _ in
            key.isEmpty ? cacheKey.contains(":") : !cacheKey.hasPrefix(key + ":")
        }
        revision &+= 1
    }

    public func retainSources(_ ids: Set<UUID>) {
        let keys = Set(ids.map(\.uuidString))
        configurations = configurations.filter { $0.key.isEmpty || keys.contains($0.key) }
        caches = caches.filter { key, _ in
            guard let prefix = key.split(separator: ":").first, UUID(uuidString: String(prefix)) != nil else { return true }
            return keys.contains(String(prefix))
        }
        revision &+= 1
    }

    public func refreshVisible(channelIDs: Set<String>) async {
        let now = Date()
        let stale = channelIDs.filter { id in
            !inFlight.contains(id) && (caches[id].map { now.timeIntervalSince($0.fetchTime) >= expiry } ?? true)
        }
        let groups = Dictionary(grouping: stale) { id -> String in
            let prefix = String(id.split(separator: ":").first ?? "")
            return UUID(uuidString: prefix) == nil ? "" : prefix
        }
        for key in groups.keys.sorted() {
            guard !Task.isCancelled, let configuration = configurations[key] else { continue }
            let ids = Array((groups[key] ?? []).sorted().prefix(50))
            inFlight.formUnion(ids)
            defer { inFlight.subtract(ids) }
            do {
                let guide: AppleIPTVGuide
                var providerIDs: [String: String] = [:]
                switch configuration {
                case .xmltv(let url, let mapping):
                    guide = try await loader.load(xmltvURL: url)
                    providerIDs = Dictionary(uniqueKeysWithValues: ids.map { ($0, mapping[$0] ?? $0) })
                case .xtream(let base, let user, let pass):
                    for id in ids {
                        let raw = key.isEmpty ? id : String(id.dropFirst(key.count + 1))
                        if let value = Int(raw), value > 0 { providerIDs[id] = String(value) }
                    }
                    guard !providerIDs.isEmpty else { continue }
                    guide = try await loader.load(xtreamBase: base, username: user, password: pass,
                        streamIDs: providerIDs.values.compactMap(Int.init).sorted())
                }
                guard !Task.isCancelled, configurations[key] == configuration else { continue }
                for id in ids {
                    guard let providerID = providerIDs[id] else { continue }
                    let programmes = guide.programmes(channelID: providerID,
                        in: DateInterval(start: .distantPast, end: .distantFuture)).map { programme in
                        AppleIPTVProgramme(id: "\(id):\(programme.id)", channelID: id, title: programme.title,
                            subtitle: programme.subtitle, description: programme.description, start: programme.start,
                            end: programme.end, category: programme.category, isLive: programme.isLive)
                    }
                    caches[id] = ChannelCache(programmes: programmes, fetchTime: now)
                }
                revision &+= 1
            } catch {
                // Keep previous data, and allow the next visible refresh to retry.
                // Cancellation or a failed provider must not cache an empty guide.
            }
        }
    }

    public func nowAndNext(channelID: String, at time: Date = Date()) -> (now: AppleIPTVProgramme?, next: AppleIPTVProgramme?) {
        guide(for: [channelID]).nowAndNext(channelID: channelID, at: time)
    }

    public func programmes(channelID: String, in interval: DateInterval) -> [AppleIPTVProgramme] {
        guide(for: [channelID]).programmes(channelID: channelID, in: interval)
    }

    public func guide(for channelIDs: some Sequence<String>) -> AppleIPTVGuide {
        var seen = Set<String>()
        let ids = channelIDs.filter { seen.insert($0).inserted }
        let revision = revision
        if let cache = guideCache, cache.revision == revision, cache.ids == ids { return cache.guide }
        let guide = AppleIPTVGuide(programmes: ids.flatMap { caches[$0]?.programmes ?? [] })
        guideCache = (ids, revision, guide)
        return guide
    }
}
