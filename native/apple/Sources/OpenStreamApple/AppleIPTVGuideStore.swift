import Foundation
import Observation

@MainActor
@Observable
public final class AppleIPTVGuideStore {
    private let loader: AppleIPTVGuideLoader
    private let diskCache: AppleIPTVGuideDiskCache
    private let clock: any AppleClock
    private struct Retry {
        let attempts: Int
        let deadline: ContinuousClock.Instant
    }
    @ObservationIgnored private var retries: [String: Retry] = [:]
    public private(set) var retryRevision = 0
    public private(set) var channelNames: [String: [String: String]] = [:]
    /// Lookup tables for the store's own loads; no view reads them. Not
    /// observed, so replacing them does not compare thousands of entries.
    @ObservationIgnored public var channelDisplayNames: [String: String] = [:]
    @ObservationIgnored public var channelProviderIDs: [String: String] = [:]
    public var manualChannelMapping: [String: String] = [:] {
        didSet {
            guard manualChannelMapping != oldValue else { return }
            restoredKeys.removeAll()
            changedSources.formUnion(configurations.keys)
            // A newly selected station must never display the old station's listings.
            for id in Set(oldValue.keys).union(manualChannelMapping.keys)
                where oldValue[id] != manualChannelMapping[id] {
                if mappingEvidence[id]?.providerID != manualChannelMapping[id] {
                    caches[id] = nil
                    mappingEvidence[id] = nil
                }
            }
            revision &+= 1
        }
    }
    public private(set) var mappingEvidence: [String: AppleIPTVGuideMappingEvidence] = [:]
    private var restoredKeys = Set<String>()

    private struct ChannelCache: Sendable {
        let programmes: [AppleIPTVProgramme]
        let fetchTime: Date
    }

    private enum Configuration: Equatable {
        case xmltv(URL, [String: String], Double, [String: Double], Double)
        case xtream(URL, String, String, Double)
    }

    private struct XMLTVCache {
        let guide: AppleIPTVGuide
        let fetchTime: Date
        let eTag: String?
        let lastModified: String?
        let contentDigest: String?
    }
    public static let xmltvExpiry: TimeInterval = 6 * 3600
    private var xmltvCaches: [String: XMLTVCache] = [:]
    private var xmltvInFlight = Set<String>()
    private var changedSources = Set<String>()
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

    public init(loader: AppleIPTVGuideLoader = AppleIPTVGuideLoader(), diskCache: AppleIPTVGuideDiskCache = .shared,
                clock: any AppleClock = AppleSystemClock()) {
        self.loader = loader
        self.diskCache = diskCache
        self.clock = clock
    }

    public func configure(xmltvURL: URL?, sourceID: UUID? = nil, channelMapping: [String: String] = [:], defaultOffsetHours: Double = 0, channelShifts: [String: Double] = [:], timeShiftHours: Double = 0) {
        setConfiguration(xmltvURL.map { .xmltv($0, channelMapping, defaultOffsetHours, channelShifts, timeShiftHours) }, key: sourceID?.uuidString ?? "")
    }

    public func configure(xtreamBase: URL, username: String, password: String, sourceID: UUID? = nil, timeShiftHours: Double = 0) {
        let key = sourceID?.uuidString ?? ""
        setConfiguration(.xtream(xtreamBase, username, password, timeShiftHours), key: key)
        channelNames[key] = Dictionary(uniqueKeysWithValues: channelDisplayNames.compactMap { id, name in
            guard key.isEmpty || id.hasPrefix(key + ":"),
                  let raw = AppleIPTVGuideMatching.xtreamID(id, sourceKey: key) else { return nil }
            return (String(raw), name)
        })
    }

    private func setConfiguration(_ value: Configuration?, key: String) {
        guard configurations[key] != value else { return }
        retries[key] = nil
        if configurations[key] != nil { changedSources.insert(key) }
        if case .xmltv(let oldURL, _, let oldOffset, _, _)? = configurations[key],
           case .xmltv(let newURL, _, let newOffset, _, _)? = value,
           oldURL == newURL, oldOffset == newOffset {
            // Mapping/shift changes can be projected from the retained raw provider guide.
        } else {
            xmltvCaches[key] = nil
            channelNames[key] = nil
        }
        configurations[key] = value
        restoredKeys.remove(key)
        if value == nil {
            caches = caches.filter { sourceKey($0.key) != key }
            mappingEvidence = mappingEvidence.filter { sourceKey($0.key) != key }
            changedSources.remove(key)
        }
        // Keep the last successful projection until a replacement is ready.
        revision &+= 1
    }

    public func retainSources(_ ids: Set<UUID>) {
        let keys = Set(ids.map(\.uuidString))
        xmltvCaches = xmltvCaches.filter { $0.key.isEmpty || keys.contains($0.key) }
        configurations = configurations.filter { $0.key.isEmpty || keys.contains($0.key) }
        retries = retries.filter { $0.key.isEmpty || keys.contains($0.key) }
        caches = caches.filter { key, _ in
            guard let prefix = key.split(separator: ":").first, UUID(uuidString: String(prefix)) != nil else { return true }
            return keys.contains(String(prefix))
        }
        mappingEvidence = mappingEvidence.filter { keys.contains(sourceKey($0.key)) || sourceKey($0.key).isEmpty }
        revision &+= 1
    }

    /// Channel ids whose panel keeps an archive; their Xtream listings are
    /// read with the past included. Set by the Live tab from the lineup.
    @ObservationIgnored public var archiveChannelIDs: Set<String> = []

    public func refreshVisible(channelIDs: Set<String>, force: Bool = false, now: Date = .now) async {
        let groups = Dictionary(grouping: channelIDs, by: sourceKey)
        await withTaskGroup(of: Void.self) { group in
            for ids in groups.values {
                group.addTask {
                    await self.refreshVisible(channelIDs: Set(ids), force: force, now: now, automaticRetry: false)
                }
            }
        }
    }

    public func restorePersisted(now: Date = .now) async {
        let started = ContinuousClock.now
        let previousRevision = revision
        for key in configurations.keys.sorted() {
            guard let configuration = configurations[key], !changedSources.contains(key), restoredKeys.insert(key).inserted else { continue }
            let assignments = manualChannelMapping
            var mapped = await diskCache.snapshot(key: evidenceDiskKey(key, configuration), now: now)
            if mapped.mappingEvidence == nil {
                mapped = await diskCache.snapshot(key: evidenceDiskKey(key, configuration, version: 1), now: now)
            }
            guard configurations[key] == configuration, manualChannelMapping == assignments, !Task.isCancelled else { continue }
            let mappedProgrammes = Dictionary(grouping: mapped.programmes, by: \.channelID)
            for (id, evidence) in mapped.mappingEvidence ?? [:] {
                guard assignments[id] == nil ? evidence.origin != .manual : assignments[id] == evidence.providerID else { continue }
                let programmes = mappedProgrammes[id] ?? []
                guard caches[id] == nil else { continue }
                caches[id] = ChannelCache(programmes: programmes, fetchTime: evidence.fetchedAt)
                var retained = evidence
                retained.coverage = AppleIPTVGuideMappingEvidence.coverage(of: programmes)
                mappingEvidence[id] = retained
            }
            if !mapped.programmes.isEmpty { revision &+= 1 }
            var snapshot = await diskCache.snapshot(key: rawDiskKey(key, configuration), now: now)
            if snapshot.isRawXMLTV == nil && snapshot.programmes.isEmpty {
                snapshot = await diskCache.snapshot(key: diskKey(key, configuration), now: now)
            }
            if snapshot.isRawXMLTV == nil && snapshot.programmes.isEmpty {
                // Before provider identity was separate, Live also folded manual assignments into the mapping key.
                snapshot = await diskCache.snapshot(key: diskKey(key, configuration, manualLegacyMapping: true), now: now)
            }
            let saved = snapshot.programmes
            guard configurations[key] == configuration, manualChannelMapping == assignments, !Task.isCancelled else { continue }
            if case .xmltv = configuration {
                channelNames[key] = snapshot.channelNames
                if snapshot.isRawXMLTV == true {
                    xmltvCaches[key] = XMLTVCache(guide: AppleIPTVGuide(programmes: saved, channelNames: snapshot.channelNames),
                        fetchTime: snapshot.fetchedAt ?? .distantPast, eTag: snapshot.eTag,
                        lastModified: snapshot.lastModified, contentDigest: snapshot.contentDigest)
                    continue
                }
            }
            for (id, programmes) in Dictionary(grouping: saved, by: \.channelID) where caches[id] == nil {
                caches[id] = ChannelCache(programmes: programmes, fetchTime: now)
            }
            if !saved.isEmpty { revision &+= 1 }
        }
        if revision != previousRevision {
            appleTrace("live guide cache restored channels=\(caches.count) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
        }
    }

    private func refreshVisible(channelIDs: Set<String>, force: Bool, now: Date, automaticRetry: Bool) async {
        await restorePersisted(now: now)
        let stale = channelIDs.filter { id in
            guard !inFlight.contains(id) else { return false }
            let key = sourceKey(id)
            if case .xmltv? = configurations[key] {
                guard !xmltvInFlight.contains(key) else { return false }
                return force || changedSources.contains(key) || !projectionIsCurrent(id, configuration: configurations[key]) || caches[id] == nil || (xmltvCaches[key].map { now.timeIntervalSince($0.fetchTime) >= Self.xmltvExpiry } ?? true)
            }
            return force || changedSources.contains(key) || !projectionIsCurrent(id, configuration: configurations[key]) || (caches[id].map { now.timeIntervalSince($0.fetchTime) >= expiry } ?? true)
        }
        let groups = Dictionary(grouping: stale) { id -> String in
            sourceKey(id)
        }
        for key in groups.keys.sorted() {
            guard !Task.isCancelled, let configuration = configurations[key] else { continue }
            let assignments = manualChannelMapping
            let limit = AppleIPTVClient.maximumChannels
            var requested = Set(groups[key] ?? [])
            if case .xmltv(_, let mapping, _, _, _) = configuration {
                requested.formUnion(caches.keys.filter { sourceKey($0) == key })
                requested.formUnion(mapping.keys)
                requested.formUnion(channelDisplayNames.keys.filter { key.isEmpty || $0.hasPrefix(key + ":") })
            }
            let ids = Array(requested.sorted().prefix(limit))
            inFlight.formUnion(ids)
            if case .xmltv = configuration { xmltvInFlight.insert(key) }
            defer { inFlight.subtract(ids); xmltvInFlight.remove(key) }
            do {
                let guide: AppleIPTVGuide
                var fileChanged = false
                var updatedXMLTV: XMLTVCache?
                var providerIDs: [String: String] = [:]
                var stagedEvidence: [String: AppleIPTVGuideMappingEvidence] = [:]
                switch configuration {
                case .xmltv(let url, let mapping, let offset, _, _):
                    let previous = xmltvCaches[key]
                    if !force, let previous, now.timeIntervalSince(previous.fetchTime) < Self.xmltvExpiry {
                        guide = previous.guide
                    } else {
                        let response = try await loader.loadXMLTV(url: url, defaultOffsetHours: offset,
                            eTag: previous?.eTag, lastModified: previous?.lastModified, contentDigest: previous?.contentDigest)
                        guard let retainedGuide = response.guide ?? previous?.guide else { throw URLError(.badServerResponse) }
                        guide = retainedGuide
                        fileChanged = response.guide != nil
                        updatedXMLTV = XMLTVCache(guide: guide, fetchTime: now, eTag: response.eTag,
                            lastModified: response.lastModified, contentDigest: response.contentDigest)
                    }
                    guard !Task.isCancelled, configurations[key] == configuration, manualChannelMapping == assignments else { continue }
                    let available = Set(guide.channelNames.keys).union(guide.channelIDs)
                    let names = channelDisplayNames.filter { sourceKey($0.key) == key }
                    let groups = Dictionary(grouping: names.keys) { AppleIPTVGuideMatching.normalize(names[$0] ?? "") }
                    let conflictingNames = Set(groups.compactMap { name, members -> String? in
                        let targets = Set(members.compactMap { id in
                            AppleIPTVGuideMappingEvidence.resolve(id: id, declaredID: mapping[id], manualID: assignments[id],
                                name: names[id] ?? id, uniqueName: true, index: guide.channelMatchIndex,
                                available: available, previous: mappingEvidence[id], fetchedAt: now)?.providerID
                        })
                        return targets.count > 1 ? name : nil
                    })
                    for id in ids {
                        let shift = shifts(for: id, configuration: configuration)
                        let evidence = AppleIPTVGuideMappingEvidence.resolve(id: id, declaredID: mapping[id],
                            manualID: assignments[id], name: names[id] ?? id,
                            uniqueName: !conflictingNames.contains(AppleIPTVGuideMatching.normalize(names[id] ?? id)),
                            index: guide.channelMatchIndex, available: available, previous: mappingEvidence[id],
                            defaultOffsetHours: offset, channelShiftHours: shift.channel,
                            correctionHours: shift.correction, fetchedAt: updatedXMLTV?.fetchTime ?? previous?.fetchTime ?? now)
                        if let evidence {
                            stagedEvidence[id] = evidence
                            providerIDs[id] = evidence.providerID
                        } else if let retained = mappingEvidence[id] {
                            stagedEvidence[id] = AppleIPTVGuideMappingEvidence(providerID: retained.providerID,
                                declaredProviderID: mapping[id], origin: retained.origin, confidence: retained.confidence,
                                defaultOffsetHours: offset, channelShiftHours: shift.channel, correctionHours: shift.correction,
                                fetchedAt: retained.fetchedAt, coverage: retained.coverage, isStale: true)
                            providerIDs[id] = retained.providerID
                        }
                    }
                case .xtream(let base, let user, let pass, _):
                    for id in ids {
                        if let value = AppleIPTVGuideMatching.xtreamID(id, manualID: assignments[id], sourceKey: key) {
                            providerIDs[id] = String(value)
                        }
                    }
                    guard !providerIDs.isEmpty else { continue }
                    let archive = Set(providerIDs.filter { archiveChannelIDs.contains($0.key) }.values.compactMap(Int.init))
                    guide = try await loader.load(xtreamBase: base, username: user, password: pass,
                        streamIDs: providerIDs.values.compactMap(Int.init).sorted(), archiveStreamIDs: archive)
                }
                guard !Task.isCancelled, configurations[key] == configuration, manualChannelMapping == assignments else { continue }
                var stagedCaches: [String: ChannelCache] = [:]
                for (index, id) in ids.enumerated() {
                    if index.isMultiple(of: 100) {
                        await Task.yield()
                        guard !Task.isCancelled, configurations[key] == configuration, manualChannelMapping == assignments else { break }
                    }
                    guard let providerID = providerIDs[id] else { continue }
                    let shift = shifts(for: id, configuration: configuration)
                    let evidence = stagedEvidence[id] ?? AppleIPTVGuideMappingEvidence(providerID: providerID,
                        declaredProviderID: channelProviderIDs[id] ?? providerID, origin: assignments[id].flatMap(Int.init) == Int(providerID) ? .manual : .providerID,
                        confidence: 1, defaultOffsetHours: 0, channelShiftHours: shift.channel,
                        correctionHours: shift.correction, fetchedAt: now, coverage: [], isStale: false)
                    let replacement = AppleIPTVGuideMappingEvidence.replacement(providerProgrammes:
                        guide.programmes(channelID: providerID, in: DateInterval(start: .distantPast, end: .distantFuture)),
                        channelID: id, evidence: evidence, previousProgrammes: caches[id]?.programmes ?? [],
                        previousEvidence: mappingEvidence[id])
                    stagedEvidence[id] = replacement.evidence
                    // Retained listings keep their data timestamp, but a successful empty response
                    // still starts the request expiry window. Restore deliberately uses fetchedAt.
                    stagedCaches[id] = ChannelCache(programmes: replacement.programmes,
                        fetchTime: replacement.evidence.isStale ? now : replacement.evidence.fetchedAt)
                }
                guard !Task.isCancelled, configurations[key] == configuration, manualChannelMapping == assignments else { continue }
                // Commit only the completed replacement. A cancelled mapping keeps the old guide.
                if let updatedXMLTV { xmltvCaches[key] = updatedXMLTV }
                retries[key] = nil
                changedSources.remove(key)
                restoredKeys.insert(key)
                caches.merge(stagedCaches) { _, new in new }
                mappingEvidence.merge(stagedEvidence) { _, new in new }
                if case .xmltv = configuration { channelNames[key] = guide.channelNames }
                revision &+= 1
                if case .xmltv = configuration {
                    if fileChanged, let snapshot = xmltvCaches[key] {
                        await diskCache.store(snapshot.guide.allProgrammes, key: rawDiskKey(key, configuration),
                            channelNames: snapshot.guide.channelNames, fetchedAt: snapshot.fetchTime, eTag: snapshot.eTag,
                            lastModified: snapshot.lastModified, contentDigest: snapshot.contentDigest, isRawXMLTV: true)
                    }
                } else {
                    let sourceProgrammes = caches.filter { cacheKey, _ in
                        key.isEmpty ? !cacheKey.contains(":") : cacheKey.hasPrefix(key + ":")
                    }.values.flatMap(\.programmes)
                    await diskCache.store(sourceProgrammes, key: diskKey(key, configuration), channelNames: channelNames[key] ?? [:])
                }
                guard !Task.isCancelled, configurations[key] == configuration, manualChannelMapping == assignments else { continue }
                let sourceCaches = caches.filter { sourceKey($0.key) == key }.mapValues(\.programmes)
                let sourceEvidence = mappingEvidence.filter { sourceKey($0.key) == key }
                if await diskCache.storeEvidence(sourceCaches, key: evidenceDiskKey(key, configuration),
                    evidence: sourceEvidence, now: now) {
                    await diskCache.remove(key: evidenceDiskKey(key, configuration, version: 1))
                }
                let filled = ids.filter { !(caches[$0]?.programmes.isEmpty ?? true) }.count
                appleTrace("guide loaded: \(filled)/\(ids.count) visible channels have programmes")
            } catch {
                guard !Task.isCancelled, configurations[key] == configuration else { continue }
                let attempts = (retries[key]?.attempts ?? 0) + 1
                let delay: Duration = .seconds(min(300, 5 * (1 << min(attempts - 1, 6))))
                retries[key] = Retry(attempts: attempts, deadline: clock.now.advanced(by: delay))
                if !automaticRetry { retryRevision &+= 1 }
                appleTrace("guide load failed for \(ids.count) channels: \(AppleDiagnosticRedactor.redact(String(describing: error)))")
                appleTrace("guide retry pending: attempt=\(attempts) delay=\(delay)")
            }
        }
    }

    /// The Live view owns this task, so leaving the foreground cancels its delay.
    public func retryFailedVisible(channelIDs: Set<String>) async {
        let keys = Set(channelIDs.map(sourceKey))
        while !Task.isCancelled {
            guard let deadline = keys.compactMap({ retries[$0]?.deadline }).min() else { return }
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            let due = keys.filter { retries[$0].map({ clock.now >= $0.deadline }) ?? false }
            let ids = channelIDs.filter { due.contains(sourceKey($0)) }
            guard inFlight.isDisjoint(with: ids), xmltvInFlight.isDisjoint(with: due) else { return }
            appleTrace("guide foreground retry for \(ids.count) channels")
            await refreshVisible(channelIDs: ids, force: true, now: .now, automaticRetry: true)
        }
    }

    private func sourceKey(_ id: String) -> String {
        let prefix = String(id.split(separator: ":").first ?? "")
        return UUID(uuidString: prefix) == nil ? "" : prefix
    }

    private func projectionIsCurrent(_ id: String, configuration: Configuration?) -> Bool {
        guard let configuration, let evidence = mappingEvidence[id] else { return false }
        let shift = shifts(for: id, configuration: configuration)
        guard evidence.channelShiftHours == shift.channel, evidence.correctionHours == shift.correction else { return false }
        if case .xmltv(_, let mapping, let offset, _, _) = configuration {
            return evidence.defaultOffsetHours == offset && evidence.declaredProviderID == mapping[id]
        }
        return evidence.declaredProviderID == (channelProviderIDs[id] ?? evidence.providerID)
    }

    private func shifts(for id: String, configuration: Configuration) -> (channel: Double, correction: Double) {
        switch configuration {
        case .xmltv(_, _, _, let shifts, let correction):
            return (AppleIPTVGuideMappingEvidence.finite(shifts[id] ?? 0), AppleIPTVGuideMappingEvidence.finite(correction))
        case .xtream(_, _, _, let correction): return (0, AppleIPTVGuideMappingEvidence.finite(correction))
        }
    }

    private func evidenceDiskKey(_ source: String, _ configuration: Configuration, version: Int = 2) -> String {
        switch configuration {
        case .xmltv(let url, _, _, _, _): return source + "|evidence-v\(version)|xmltv|" + url.absoluteString
        case .xtream(let url, let user, let password, _): return source + "|evidence-v\(version)|xtream|" + url.absoluteString + "|" + user + "|" + password
        }
    }

    private func rawDiskKey(_ source: String, _ configuration: Configuration) -> String {
        switch configuration {
        case .xmltv(let url, _, let offset, _, _): return source + "|raw-v1|" + url.absoluteString + "|" + String(offset)
        case .xtream: return diskKey(source, configuration)
        }
    }

    private func diskKey(_ source: String, _ configuration: Configuration, manualLegacyMapping: Bool = false) -> String {
        switch configuration {
        case .xmltv(let url, let mapping, let offset, let shifts, let correction):
            var legacyMapping = mapping
            if manualLegacyMapping {
                for (id, manual) in manualChannelMapping where sourceKey(id) == source &&
                    (mapping[id] != nil || channelDisplayNames[id] != nil) {
                    legacyMapping[id] = manual
                }
            }
            return source + "|" + url.absoluteString + "|" + String(offset) + "|" + String(correction)
                + "|" + manualChannelMapping.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "|")
                + "|" + legacyMapping.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "|")
                + "|" + shifts.sorted { $0.key < $1.key }.map { $0.key + "=" + String($0.value) }.joined(separator: "|")
        case .xtream(let url, let user, let password, let correction):
            return source + "|" + url.absoluteString + "|" + user + "|" + password + "|" + String(correction)
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

extension AppleIPTVGuideStore {
    /// Points the store at every enabled Live source's guide, as the Live tab
    /// does before each refresh; the launch prefetch fills the same disk caches.
    /// A playlist can list one channel id twice; the first entry wins, as it
    /// does in the lineup, instead of trapping at launch. False when a panel's
    /// Keychain item could not be read, so its guide is not configured yet.
    @discardableResult
    func configure(liveSources sources: [AppleSource], channels: [AppleIPTVChannel],
                   sourceStore: AppleSourceStore, settings: AppleSettingsStore) -> Bool {
        var complete = true
        channelDisplayNames = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        channelProviderIDs = Dictionary(channels.compactMap { channel in
            channel.guideID.map { (channel.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        manualChannelMapping = settings.guideChannelAssignments
        retainSources(Set(sources.map(\.id)))
        archiveChannelIDs = Set(channels.lazy.filter(AppleIPTVCatchUp.supportsCatchUp).map(\.id))
        for source in sources {
            if source.iptvType == .xtream {
                guard let credentials = try? sourceStore.iptvCredentials(for: source) else {
                    complete = false
                    continue
                }
                configure(xtreamBase: source.url, username: credentials.username, password: credentials.password, sourceID: source.id,
                    timeShiftHours: Double(settings.guideTimeOffsets[source.id.uuidString] ?? 0))
            } else {
                let sourceChannels = channels.filter { $0.sourceID == source.id }
                let mapping = sourceChannels.reduce(into: [String: String]()) { result, channel in
                    if let id = channel.guideID { result[channel.id] = id }
                }
                configure(xmltvURL: sourceChannels.first?.guideURL, sourceID: source.id, channelMapping: mapping,
                    defaultOffsetHours: sourceChannels.first?.guideDefaultOffsetHours ?? 0,
                    channelShifts: Dictionary(sourceChannels.compactMap { channel in
                        channel.guideShiftHours.map { (channel.id, $0) }
                    }, uniquingKeysWith: { first, _ in first }), timeShiftHours: Double(settings.guideTimeOffsets[source.id.uuidString] ?? 0))
            }
        }
        return complete
    }
}

/// The Live tab configures its guide again only when something
/// `configure(liveSources:channels:sourceStore:settings:)` reads has changed:
/// it walks the whole lineup and reads each panel's Keychain item. Its only
/// caller with the Live tab's store; the launch prefetch configures its own.
@MainActor
final class AppleLiveGuideConfiguration {
    private var configured: String?

    func needsConfigure(_ key: String, force: Bool) -> Bool {
        force || configured != key
    }

    /// A configure that missed a Keychain item is not recorded, so the next
    /// refresh reads it again.
    func didConfigure(_ key: String, complete: Bool) {
        configured = complete ? key : nil
    }

    /// The lineup by revision (names, guide ids and addresses, shifts and
    /// archives all come from the channels); each source's addresses,
    /// credentials item and edits (`configurationRevision`, bumped by a
    /// credentials edit); the guide offsets and assignments (the manual
    /// mapping). Hidden channels and groups are not read.
    static func key(sources: [AppleSource], channelsRevision: Int,
                    timeOffsets: [String: Int], assignments: [String: String]) -> String {
        let parts = sources.map { source in
            [source.id.uuidString, String(source.configurationRevision), String(source.isEnabled), String(source.needsSignIn),
             source.iptvType?.rawValue ?? "", source.url.absoluteString, source.epgURL?.absoluteString ?? "",
             source.credentialReference ?? ""].joined(separator: "|")
        } + [String(channelsRevision),
             timeOffsets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
             assignments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
        return ApplePlaybackIdentity.digest(for: parts.joined(separator: "\u{1f}"))
    }
}
