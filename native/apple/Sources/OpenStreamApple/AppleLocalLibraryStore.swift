import Foundation
import Observation
import SwiftUI

/// Shared discovery and playback identity for Folder, SMB and downloaded files.
@MainActor @Observable
final class AppleLocalLibraryStore {
    static let shared = AppleLocalLibraryStore()
    #if DEBUG
    /// False under the Library titles fixture (`AppleLibraryTitlesDebugView`):
    /// a fixture scan must never replace the real library's snapshot or its
    /// last-scan stamp, which live in the same container.
    static var persistsScanResults = true
    #else
    static let persistsScanResults = true
    #endif
    static let downloadsID = UUID(uuidString: "EB7EF704-5724-4CEB-88B9-2860E474BD70")!
    private(set) var groups: [AppleLibrarySeries] = []
    private(set) var sources: [AppleSource] = []
    private(set) var metadata: [String: AppleCatalogItem] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var progress: [String: ApplePlaybackProgress] = [:]
    private var offlineIDs: [String: String] = [:]
    private(set) var lastScan: Date?
    
    struct AppleLibraryGroupSnapshot: Codable {
        let id: String
        let title: String
        let year: Int?
        let kind: AppleLibraryTitle.Kind
        struct Item: Codable {
            let id: String
            let sourceID: UUID
            let name: String
            let url: URL
            let relativePath: String
            let sizeBytes: Int64
            let addedAt: Date
        }
        let items: [Item]
    }

    /// Reset OpenStream: the saved index is gone, so is this copy.
    func discardAfterReset() {
        groups = []
        sources = []
        metadata = [:]
        isLoading = false
        errorMessage = nil
        progress = [:]
        offlineIDs = [:]
        lastScan = nil
        contentDidChange()
    }

    func publishPersistedIndex(activeSources: [AppleSource]) async -> Bool {
        let activeSourceIDs = Set(activeSources.map(\.id))
        
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenStream")
        let snapshotURL = caches.appendingPathComponent("LibraryGroups-v1.json")
        
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshots = try? JSONDecoder().decode([AppleLibraryGroupSnapshot].self, from: data) else {
            appleTrace("library persisted index unusable: no snapshot found")
            return false
        }
        
        var realGroups: [AppleLibrarySeries] = []
        var publishedCount = 0
        
        for snapshot in snapshots {
            let activeItems = snapshot.items.filter { activeSourceIDs.contains($0.sourceID) }
            guard !activeItems.isEmpty else { continue }
            
            let parsed = AppleLibraryTitle(title: snapshot.title, year: snapshot.year, season: nil, episode: nil, kind: snapshot.kind)
            let items = activeItems.map { AppleLibraryItem(sourceID: $0.sourceID, name: $0.name, url: $0.url, relativePath: $0.relativePath, sizeBytes: $0.sizeBytes, addedAt: $0.addedAt) }
            
            let group = AppleLibrarySeries(id: snapshot.id, parsed: parsed, items: items)
            realGroups.append(group)
            publishedCount += 1
        }
        
        guard publishedCount > 0 else {
            appleTrace("library persisted index unusable: empty after filtering")
            return false
        }
        
        self.sources = activeSources
        self.groups = realGroups
        contentDidChange()
        appleTrace("library published from persisted index: \(publishedCount) titles")
        return true
    }
    /// Bumped whenever `groups` or `metadata` changes, so `sortedCache` knows
    /// when its answer is stale. `@Observable` forbids property observers, so
    /// every mutation site calls `contentDidChange()` by hand.
    private(set) var contentRevision = 0
    @ObservationIgnored private var sortedCache: [AppleLibrarySort: (revision: Int, value: [AppleLibrarySeries])] = [:]

    private func contentDidChange() {
        contentRevision &+= 1
        sortedCache.removeAll(keepingCapacity: true)
        publishDiscKeys()
    }

    /// Groups holding a disc image (`AppleDiscImagePolicy`), worked out once
    /// per scan rather than on every metadata change.
    @ObservationIgnored private var discGroupIDs: Set<String> = []
    @ObservationIgnored private var discGroupSignature = -1

    /// The catalog keys whose posters carry the disc badge: each disc
    /// group's own card and the title it resolved to, so Discover, Search and
    /// Library all mark it.
    private func publishDiscKeys() {
        let signature = groups.count &+ groups.reduce(0) { $0 &+ $1.items.count }
        if signature != discGroupSignature {
            discGroupSignature = signature
            discGroupIDs = Set(groups.filter { $0.items.contains(where: AppleDiscImagePolicy.isDiscImage) }.map(\.id))
        }
        var keys = Set<String>()
        for group in groups where discGroupIDs.contains(group.id) {
            let item = catalogItem(for: group)
            keys.insert(item.id)
            keys.insert(AppleDiscCatalog.matchKey(item))
        }
        AppleDiscCatalog.shared.replaceKeys(keys)
    }

    /// The disc file among a title's files, if any.
    func discFile(in files: [AppleLibraryItem]) -> AppleLibraryItem? {
        files.first(where: AppleDiscImagePolicy.isDiscImage)
    }

    /// What a local file is, read once per file: the engine's probe for the
    /// format badges, and for a disc image the titles on it. Only files on
    /// this device (a folder or a download), never a share: no network.
    @ObservationIgnored private var inspections: [String: AppleLocalFileInspection] = [:]

    func inspection(for file: AppleLibraryItem) async -> AppleLocalFileInspection? {
        if let cached = inspections[file.id] { return cached }
        guard file.url.isFileURL, let source = sources.first(where: { $0.id == file.sourceID }),
              source.kind == .library else { return nil }
        let root = file.sourceID == Self.downloadsID ? nil : try? AppleLibraryBookmark.resolve(source)
        let url = file.url
        let isDisc = AppleDiscImagePolicy.isDiscImage(file)
        let result = await Task.detached(priority: .utility) { () -> AppleLocalFileInspection in
            let access = root.map { AppleSecurityScopedAccess(url: $0) }
            defer { withExtendedLifetime(access) {} }
            return AppleLocalFileInspection.inspect(url: url, isDisc: isDisc)
        }.value
        inspections[file.id] = result
        if !result.discTitles.isEmpty { AppleDiscCatalog.shared.record(result.discTitles, for: url) }
        appleTrace("local inspect \(url.lastPathComponent.suffix(40)): badges=\(result.badges.map(\.title)) discTitles=\(result.discTitles.count)")
        return result
    }

    static func matches(_ lhs: AppleCatalogItem, _ rhs: AppleCatalogItem) -> Bool {
        guard lhs.type == rhs.type else { return false }
        if lhs.mediaID.hasPrefix("tt"), rhs.mediaID.hasPrefix("tt") { return lhs.mediaID == rhs.mediaID }
        return normalized(lhs.name) == normalized(rhs.name)
            && String((lhs.releaseInfo ?? "").prefix(4)) == String((rhs.releaseInfo ?? "").prefix(4))
    }
    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    func catalogItem(for group: AppleLibrarySeries) -> AppleCatalogItem {
        metadata[group.id] ?? AppleCatalogItem(mediaID: "local-" + ApplePlaybackIdentity.digest(for: group.id),
            type: group.parsed.kind == .show ? "series" : "movie", name: group.parsed.title,
            releaseInfo: group.parsed.year.map(String.init))
    }
    func matchingGroups(_ item: AppleCatalogItem) -> [AppleLibrarySeries] {
        groups.filter { Self.matches(catalogItem(for: $0), item) }
    }
    var resolvedGroups: [AppleLibrarySeries] {
        var seen = Set<String>()
        return sorted(.added).filter {
            guard let item = metadata[$0.id] else { return false }
            let key = item.mediaID.hasPrefix("tt") ? item.mediaID : "\(item.type):\(Self.normalized(item.name)):\(item.releaseInfo ?? "")"
            return seen.insert(key).inserted
        }
    }
    var featured: AppleLibrarySeries? { featuredCandidates.first }

    /// The billboard rotates through these rather than pinning the newest
    /// title, so Library does not open on the same film every time.
    var featuredCandidates: [AppleLibrarySeries] {
        AppleHeroRotation.candidates(
            sorted(.added).filter { $0.parsed.kind == .movie && metadata[$0.id]?.backgroundURL != nil },
            id: \.id
        )
    }
    /// One card per film. Files whose names differ ("Tony.2026.1080p",
    /// "Tony 4K") land in separate groups but resolve to one IMDb title —
    /// N32 #13 drew "Tony" twice. The first in display order stays; the rest
    /// are still found by `matchingGroups`, so the title page lists every
    /// file under Other Sources.
    nonisolated static func collapsingVersions(_ decorated: [(group: AppleLibrarySeries, item: AppleCatalogItem)]) -> [AppleLibrarySeries] {
        var seen = Set<String>()
        return decorated.compactMap { group, item in
            guard group.parsed.kind == .movie, item.mediaID.hasPrefix("tt"),
                  let sourceID = group.items.first?.sourceID else { return group }
            return seen.insert("\(sourceID):\(item.mediaID)").inserted ? group : nil
        }
    }
    /// Decorate once, sort, undecorate — and remember the answer until the
    /// content changes.
    ///
    /// The comparator used to call `catalogItem(for:)` on *both* sides of
    /// every comparison, and a metadata miss there constructs an item and
    /// digests the group id: ~29,000 of those for the owner's 1,397-file
    /// library, on a sort that `AppleLibraryView` asks for five to eight
    /// times per body pass. That is why Library stayed blank for seven
    /// seconds after its scan had already finished at 2.5s, and why scrolling
    /// it crawled (owner, 2026-09-15). Decorating drops it to one call per
    /// group; the memo drops repeat passes to nothing.
    ///
    /// The memo is not observed, so a hit reads `groups` and `metadata` first:
    /// a shelf whose body reads only this still redraws when the scan or a
    /// title's metadata lands.
    func sorted(_ sort: AppleLibrarySort) -> [AppleLibrarySeries] {
        _ = groups
        _ = metadata
        if let cached = sortedCache[sort], cached.revision == contentRevision { return cached.value }
        let decorated = groups.map { (group: $0, item: catalogItem(for: $0)) }
        let ordered = decorated.sorted {
            if sort == .added, $0.group.addedAt != $1.group.addedAt { return $0.group.addedAt > $1.group.addedAt }
            if sort == .year, $0.item.releaseInfo != $1.item.releaseInfo {
                return ($0.item.releaseInfo ?? "") > ($1.item.releaseInfo ?? "")
            }
            return $0.item.name == $1.item.name
                ? $0.group.id < $1.group.id
                : $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
        let value = Self.collapsingVersions(ordered)
        sortedCache[sort] = (contentRevision, value)
        return value
    }
    var continueWatching: [AppleLibrarySeries] {
        let store = ApplePlaybackStore()
        return groups.filter { group in
            progress[group.id] != nil && group.items.contains { file in
                store.progress(for: playbackID(file))?.resumePosition != nil
                    && !store.isRemovedFromContinueWatching(mediaID: playbackID(file))
            }
        }.sorted { progress[$0.id]!.updatedAt > progress[$1.id]!.updatedAt }
    }
    func refreshProgress() {
        let store = ApplePlaybackStore()
        var values: [String: ApplePlaybackProgress] = [:]
        for group in groups {
            for file in group.items {
                if let value = store.progress(for: playbackID(file)), value.resumePosition != nil,
                   value.updatedAt > (values[group.id]?.updatedAt ?? .distantPast) { values[group.id] = value }
            }
        }
        progress = values
    }
    func playbackID(_ file: AppleLibraryItem) -> String {
        if let id = offlineIDs[file.id] { return id }
        guard let source = sources.first(where: { $0.id == file.sourceID }) else { return file.id }
        return AppleMediaIngestion.libraryRecord(source: source, item: file).id
    }
    func resolve(_ group: AppleLibrarySeries, sourceStore: AppleSourceStore, settings: AppleSettingsStore) async {
        guard metadata[group.id] == nil, let file = group.items.first else { return }
        if let value = try? await AppleLibraryMetadataResolver.shared.resolve(file, sources: sourceStore.sources,
            tmdbKey: settings.tmdbAPIKey, omdbKey: settings.omdbAPIKey), !Task.isCancelled {
            metadata[group.id] = value
            contentDidChange()
        }
    }
    func reload(sourceStore: AppleSourceStore, mediaIndex: AppleMediaIndexStore, settings: AppleSettingsStore) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        sources = sourceStore.sources.filter { $0.isEnabled && ($0.kind == .library || $0.kind == .nas) }
        var files: [AppleLibraryItem] = []
        var errors: [String] = []
        var pendingIndexWrites: [(source: AppleSource, items: [AppleLibraryItem])] = []
        for source in sources {
            do {
                let scanned: [AppleLibraryItem]
                if source.kind == .nas {
                    let credentials = try sourceStore.networkCredentials(for: source) ?? AppleSMBCredentials(username: "", password: "")
                    scanned = try await AppleSMBNetworkLibraryScanner(client: AppleSMBClient()).scan(source: source, credentials: credentials)
                } else { scanned = try await AppleLibraryScanner().scan(source: source) }
                let dated = try await AppleLibraryMetadataResolver.shared.datedItems(scanned, sourceID: source.id)
                appleTrace("library scanned \"\(source.name)\": \(scanned.count) files")
                files += dated
                sourceStore.recordValidationSuccess(id: source.id, summary: "Connected · \(scanned.count) playable files",
                    discoveredItemCount: scanned.count, capabilities: ["Browse", "Playback", "Seeking"])
                pendingIndexWrites.append((source, dated))
            } catch is CancellationError { return }
            catch {
                appleTraceFailure("library scan \"\(source.name)\" failed: \(error.localizedDescription)")
                errors.append("\(source.name): \(error.localizedDescription)")
                sourceStore.recordValidationFailure(id: source.id, summary: error.localizedDescription)
            }
        }
        appleTrace("library scans done, \(files.count) files")
        let downloads = await AppleOfflineMediaStore().allRecords()
        appleTrace("library downloads read: \(downloads.count)")
        var newOfflineIDs: [String: String] = [:]
        var newMetadata: [String: AppleCatalogItem] = [:]
        if !downloads.isEmpty {
            sources.append(AppleSource(id: Self.downloadsID, kind: .library, name: "Downloads", url: downloads[0].localURL.deletingLastPathComponent()))
            for record in downloads {
                let indexed = mediaIndex.record(matchingMediaID: record.mediaID)
                let filename = [record.title ?? indexed?.title ?? record.localURL.deletingPathExtension().lastPathComponent,
                    indexed?.year.map(String.init), record.subtitle].compactMap { $0 }.joined(separator: " ")
                let file = AppleLibraryItem(sourceID: Self.downloadsID, name: filename,
                    url: record.localURL, relativePath: record.localURL.lastPathComponent, sizeBytes: 0, addedAt: record.storedAt)
                files.append(file)
                newOfflineIDs[file.id] = record.mediaID
                // Download record ids are index identities, not necessarily IMDb ids.
                let group = AppleLibrarySeries.groups([file])[0]
                newMetadata[group.id] = AppleCatalogItem(mediaID: indexed?.canonicalID ?? "local-" + ApplePlaybackIdentity.digest(for: record.mediaID),
                    type: group.parsed.kind == .show ? "series" : "movie", name: indexed?.title ?? record.title ?? group.parsed.title,
                    posterURL: record.artworkURL, summary: indexed?.summary, releaseInfo: (indexed?.year ?? group.parsed.year).map(String.init))
            }
        }
        let snapshot = files
        groups = await Task.detached { AppleLibrarySeries.groups(snapshot) }.value
        offlineIDs = newOfflineIDs
        metadata.merge(newMetadata) { current, _ in current }
        contentDidChange()
        appleTrace("library grouped: \(groups.count) titles")
        // Everything the shelves need is in `groups` now, so the tab can draw.
        //
        // The media index feeds search and Discover matching, not the
        // Library's own shelves, but writing its 1,397 records took 1.9s and
        // used to run inside the scan loop — between the scan finishing and
        // the grouping that actually produces the rows. The tab therefore held
        // a spinner for nearly three seconds after it already had the files
        // (measured 2026-09-15). The write still happens, just no longer in
        // front of the picture.
        for (source, items) in pendingIndexWrites {
            do {
                try await mediaIndex.replace(instanceID: source.id, with: AppleMediaIngestion.libraryRecords(source: source, items: items))
            } catch is CancellationError { return }
            catch {
                // This device's own storage, not the source: the shelves are
                // already drawn from `groups`, and the next scan writes the
                // index again. Nothing for the viewer to read or fix (build
                // 17 showed Apple TV's raw "You don't have permission to save
                // the file …" under the NAS), so it goes to the trace only.
                appleTraceFailure("library index write failed: \(appleErrorLabel(error))")
            }
        }
        appleTrace("library index written")
        #if DEBUG
        // `defaults write com.orgista.openstream OpenStreamLibraryTitleDump -bool YES`
        // prints what each file parsed to, so a card showing a number can be
        // traced back to the name on disk without opening the share.
        if UserDefaults.standard.bool(forKey: "OpenStreamLibraryTitleDump") {
            for group in groups {
                let parsed = group.parsed
                print("[OpenStream] title raw=\(group.items.first?.relativePath ?? "?") -> \(parsed.title) kind=\(parsed.kind.rawValue) year=\(parsed.year.map(String.init) ?? "-")")
            }
        }
        // `defaults write com.orgista.openstream OpenStreamLibraryTitleFilter
        // -string 1992` traces just the titles containing that text. The full
        // dump above goes to the console and is 1397 lines long, which neither
        // fits the trace's ring buffer nor answers a question about one card.
        if let needle = UserDefaults.standard.string(forKey: "OpenStreamLibraryTitleFilter")?.lowercased(),
           !needle.isEmpty {
            for group in groups where
                (group.items.first?.relativePath ?? "").lowercased().contains(needle)
                || group.parsed.title.lowercased().contains(needle) {
                let parsed = group.parsed
                appleTrace(
                    "library title raw=\"\(group.items.first?.relativePath ?? "?")\" → "
                    + "\"\(parsed.title)\" kind=\(parsed.kind.rawValue) "
                    + "year=\(parsed.year.map(String.init) ?? "-") groupID=\(group.id)"
                )
            }
        }
        #endif
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        let cached = await AppleLibraryMetadataResolver.shared.cachedMetadata(for: groups)
        metadata.merge(cached) { current, _ in current }
        contentDidChange()
        appleTrace("library cached metadata merged: \(cached.count)")
        refreshProgress()
        appleTrace("library progress refreshed")
        // Bound eager work. Visible cards resolve the rest on demand.
        for group in sorted(.added).filter({ $0.parsed.kind != .other }).prefix(24) {
            guard !Task.isCancelled else { return }
            await resolve(group, sourceStore: sourceStore, settings: settings)
        }
        appleTrace("library eager metadata resolved")
        lastScan = Date()
        let sourceDigest = ApplePlaybackIdentity.digest(for: sources.map(\.id.uuidString).sorted().joined(separator: ","))
        
        let snapshots = groups.map { group in
            AppleLibraryGroupSnapshot(
                id: group.id,
                title: group.parsed.title,
                year: group.parsed.year,
                kind: group.parsed.kind,
                items: group.items.map { AppleLibraryGroupSnapshot.Item(id: $0.id, sourceID: $0.sourceID, name: $0.name, url: $0.url, relativePath: $0.relativePath, sizeBytes: $0.sizeBytes, addedAt: $0.addedAt) }
            )
        }
        guard Self.persistsScanResults else { return }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("OpenStream")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let url = dir.appendingPathComponent("LibraryGroups-v1.json")
            if let data = try? JSONEncoder().encode(snapshots) {
                try? data.write(to: url, options: .atomic)
            }
        }
        
        AppleLaunchWorkPolicy.recordScan(sourceDigest: sourceDigest, date: lastScan ?? Date())
    }
    func localFiles(for item: AppleCatalogItem, group: AppleLibrarySeries? = nil, episode: AppleStremioEpisode? = nil) -> [AppleLibraryItem] {
        let matches = matchingGroups(item)
        let groups = matches.isEmpty ? group.map { [$0] } ?? [] : matches
        return groups.flatMap { group in
            group.items.enumerated().compactMap { index, file -> AppleLibraryItem? in
                guard item.type == "series" else { return file }
                guard let episode else { return nil }
                let parsed = AppleLibraryTitleParser.parse(file)
                return (parsed.season ?? 1) == episode.season && (parsed.episode ?? index + 1) == episode.episode ? file : nil
            }
        }.sorted {
            let lhs = AppleStremioCandidateRanking.resolution($0.name)
            let rhs = AppleStremioCandidateRanking.resolution($1.name)
            if lhs != rhs { return lhs > rhs }
            return $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt > $1.addedAt
        }
    }
    func resumeEpisode(for item: AppleCatalogItem, group: AppleLibrarySeries?, episodes: [AppleStremioEpisode]) -> AppleStremioEpisode? {
        let matches = matchingGroups(item)
        let candidates = matches.isEmpty ? group.map { [$0] } ?? [] : matches
        let store = ApplePlaybackStore()
        return Self.resumeEpisode(in: candidates, episodes: episodes) { store.progress(for: self.playbackID($0)) }
    }
    static func resumeEpisode(in groups: [AppleLibrarySeries], episodes: [AppleStremioEpisode],
                              progress: (AppleLibraryItem) -> ApplePlaybackProgress?) -> AppleStremioEpisode? {
        var newest = Date.distantPast
        var selected: AppleStremioEpisode?
        for group in groups {
            for (index, file) in group.items.enumerated() {
                guard let value = progress(file), value.resumePosition != nil, value.updatedAt > newest else { continue }
                let parsed = AppleLibraryTitleParser.parse(file)
                if let episode = episodes.first(where: { $0.season == (parsed.season ?? 1) && $0.episode == (parsed.episode ?? index + 1) }) {
                    selected = episode
                    newest = value.updatedAt
                }
            }
        }
        return selected
    }
    static func episodes(group: AppleLibrarySeries, mediaID: String, enriched: [AppleStremioEpisode]) -> [AppleStremioEpisode] {
        var seen = Set<String>()
        return group.items.enumerated().compactMap { index, file in
            let parsed = AppleLibraryTitleParser.parse(file)
            let season = parsed.season ?? 1, number = parsed.episode ?? index + 1
            let id = "\(mediaID):\(season):\(number)"
            guard seen.insert(id).inserted else { return nil }
            return enriched.first { $0.season == season && $0.episode == number }
                ?? AppleStremioEpisode(id: id, title: "Episode \(number)", season: season, episode: number)
        }
    }
    static func format(_ file: AppleLibraryItem) -> String {
        let resolution = file.name.range(of: #"(?i)\b(?:\d{3,4}p|[48]K)\b"#, options: .regularExpression).map { String(file.name[$0]).uppercased() }
        return [resolution, file.url.pathExtension.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func presentation(for file: AppleLibraryItem, sourceStore: AppleSourceStore, settings: AppleSettingsStore,
                      fromBeginning: Bool = false,
                      disc: AppleDiscPlaybackChoice? = nil) async throws -> AppleStremioPlayerPresentation {
        // A disc image always opens through one start choice (Play Disc
        // unless the page said otherwise), carried to the engine.
        let disc = AppleDiscImagePolicy.isDiscImage(file) ? disc ?? AppleDiscPlaybackChoice(start: .menu, titleID: nil) : nil
        let resume = AppleTitlePagePolicy.startPosition(
            saved: ApplePlaybackStore().progress(for: playbackID(file))?.resumePosition, fromBeginning: fromBeginning)
        guard let source = sources.first(where: { $0.id == file.sourceID }) else { throw AppleLibrarySourceError.unavailable }
        let title = AppleLibraryTitleParser.parse(file).title
        if source.kind == .nas {
            let credentials = try sourceStore.networkCredentials(for: source) ?? AppleSMBCredentials(username: "", password: "")
            let url = try await AppleSMBRangeServer.shared.playbackURL(sourceURL: file.url, credentials: credentials, sizeBytes: file.sizeBytes)
            var request = AppleSMBPlaybackRequestFactory.make(source: source, item: file, playbackURL: url)
            request.resumePosition = resume
            request.hints.disc = disc
            return tracked(AppleStremioPlayerPresentation(request: request, settings: settings), file: file)
        }
        let root = file.sourceID == Self.downloadsID ? nil : try AppleLibraryBookmark.resolve(source)
        let access = root.map { AppleSecurityScopedAccess(url: $0) }
        defer { withExtendedLifetime(access) {} }
        let prepared = try await ApplePlaybackPreparer().prepareLibraryMedia(sourceURL: file.url, preferredEngine: settings.playbackEngine)
        var hints = ApplePlaybackRequest.Hints(libraryFileURL: file.url)
        hints.disc = disc
        return tracked(AppleStremioPlayerPresentation(request: ApplePlaybackRequest(url: prepared.url, headers: prepared.requestHeaders,
            resumePosition: resume, mediaID: playbackID(file), title: title, sourceKind: .files, hints: hints), settings: settings, securityScopedURL: root), file: file)
    }
    private func tracked(_ presentation: AppleStremioPlayerPresentation, file: AppleLibraryItem) -> AppleStremioPlayerPresentation {
        let store = ApplePlaybackStore()
        let identity = playbackID(file)
        presentation.coordinator.progressWriter = { position, duration in
            store.save(mediaID: identity, position: position, duration: duration)
        }
        return presentation
    }

}

struct AppleLocalTitleShelf: View {
    let title: String
    let groups: [AppleLibrarySeries]
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    /// The bar of the tab the shelf sits on, for the title pages it opens.
    let tabToolbar: AppleTabToolbarContext?
    var showsProgress = false
    var accessory: AnyView? = nil
    var previewLimit: Int? = nil
    var opensFullList = true
    @State private var library = AppleLocalLibraryStore.shared
    @FocusState private var focusedItemID: String?

    var body: some View {
        AppleHomeShelf(title: title, accessory: accessory, headingIdentifier: "library.shelf.\(title)", opensFullList: opensFullList) {
            ForEach(Array(groups.prefix(previewLimit ?? groups.count))) { group in
                tile(group).focused($focusedItemID, equals: group.id)
            }
        } destination: {
            List(groups) { group in
                NavigationLink {
                    AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
                        settings: settings, openSettings: openSettings, tabToolbar: tabToolbar)
                } label: {
                    let item = library.catalogItem(for: group)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline)
                        if let year = item.releaseInfo { Text(year).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
                .navigationTitle(title)
                .scrollIndicators(.never)
                .task(id: groups.map(\.id)) { library.refreshProgress() }
        }
        .environment(\.appleTMDBConfiguration, settings.tmdbConfiguration)
        #if os(tvOS)
        .defaultFocus($focusedItemID, groups.first?.id)
        .task(id: focusedItemID) {
            guard let group = groups.first(where: { $0.id == focusedItemID }) else { return }
            try? await Task.sleep(for: AppleMetadataPrefetcher.focusDwell)
            guard !Task.isCancelled else { return }
            await library.resolve(group, sourceStore: sourceStore, settings: settings)
            let item = library.catalogItem(for: group)
            if let target = AppleMetadataPrefetcher.detailTarget(type: item.type, mediaID: item.mediaID) {
                await AppleMetadataPrefetcher.warmDetail(target, sources: sourceStore.sources,
                    preferredSourceID: group.items.first?.sourceID, configuration: settings.tmdbConfiguration)
            }
        }
        #endif
    }

    private func tile(_ group: AppleLibrarySeries) -> some View {
        AppleLocalLibraryTile(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
            settings: settings, openSettings: openSettings, tabToolbar: tabToolbar, showsProgress: showsProgress)
    }

}

struct AppleLocalTitleDestination: View {
    let group: AppleLibrarySeries
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    let tabToolbar: AppleTabToolbarContext?
    var autoPlay = false
    @State private var library = AppleLocalLibraryStore.shared
    var body: some View {
        if let source = library.sources.first(where: { $0.id == group.items.first?.sourceID }) {
            AppleCatalogItemDetailView(item: library.catalogItem(for: group), source: source, mediaIndex: mediaIndex,
                playbackSources: sourceStore.sources, metadataConfiguration: settings.metadataEnabled ? try? AppleTMDBConfiguration(credential: settings.tmdbAPIKey) : nil,
                gatewayConfig: settings.gatewayEnabled ? try? AppleTranscodeGatewayConfig(baseURL: settings.gatewayURL,
                    sessionToken: settings.gatewayToken, isEnabled: true) : nil,
                playbackResolver: AppleStremioPlaybackResolver(), settings: settings,
                openSettings: openSettings, initialAutoPlay: autoPlay, localGroup: group, localSourceStore: sourceStore,
                tabToolbar: tabToolbar)
        }
    }
}
