import Foundation
import Synchronization
#if DEBUG
import os
#endif

/// One immutable projection per lineup/filter change. SwiftUI reads these
/// arrays directly instead of normalizing every channel during each render.

final class AppleLiveChannelMatchCache: Sendable {
    static let shared = AppleLiveChannelMatchCache()

    private struct State {
        var matches = [String: AppleChannelLineupEntry?]()
        var lastEntries: [AppleChannelLineupEntry] = []
        /// Bumped on every lineup change, so matches computed (outside the lock)
        /// against an older lineup are dropped instead of cached under the new one.
        var generation = 0
    }

    private let state = Mutex(State())
    
    func match(channels: [AppleIPTVChannel], entries: [AppleChannelLineupEntry]) -> [String: AppleChannelLineupEntry] {
        let (computedGeneration, cachedResult, toCompute) = state.withLock { state in
            if entries != state.lastEntries {
                state.matches.removeAll()
                state.lastEntries = entries
                state.generation += 1
            }
            var result = [String: AppleChannelLineupEntry](minimumCapacity: channels.count)
            var toCompute = [(String, String)]()
            for channel in channels {
                let key = "\(channel.id)|\(channel.name)"
                if let cached = state.matches[key] {
                    if let entry = cached { result[channel.id] = entry }
                } else {
                    toCompute.append((channel.id, channel.name))
                }
            }
            return (state.generation, result, toCompute)
        }
        var result = cachedResult
        
        if toCompute.isEmpty { return result }
        
        let count = toCompute.count
        #if DEBUG
        AppleLiveChannelSnapshot.debugMatchCallsCounter?.calls.withLock { $0 += count }
        #endif
        
        var computed = [(String, AppleChannelLineupEntry?)]()
        computed.reserveCapacity(toCompute.count)
        let lineupIndex = AppleChannelLineupIndex(entries)
        for (id, name) in toCompute {
            let entry = lineupIndex.match(name)
            computed.append(("\(id)|\(name)", entry))
            if let e = entry { result[id] = e }
        }
        
        state.withLock { state in
            guard state.generation == computedGeneration else { return }
            for (k, v) in computed {
                state.matches[k] = v
            }
        }
        
        return result
    }
}

struct AppleLiveChannelSnapshot: Sendable {
#if DEBUG
    final class DebugCounter: Sendable {
        let calls = OSAllocatedUnfairLock<Int>(initialState: 0)
    }
    @TaskLocal static var debugMatchCallsCounter: DebugCounter?
    /// A private cache for a test that counts matches, so other suites
    /// building with other lineups in parallel cannot clear it mid-test.
    @TaskLocal static var debugMatchCache: AppleLiveChannelMatchCache?
#endif

    /// How many lineup numbers the Complete Guide must match before All is
    /// allowed to show only the lineup.
    ///
    /// Eight is far below the owner's real provider (a few hundred of 9,376) and
    /// far above an accidental name collision (one or two), so it separates
    /// "this lineup describes this source" from "this lineup happens to share a
    /// channel name with it" with room on both sides.
    static let minimumLineupMatches = 8

    /// The group `AppleChannelProjection.completeGuideGroups` gives the curated
    /// lineup; anything it could not match lands in its sibling "Other" group.
    static let completeGroupName = "Complete Guide"

    /// The most channels the guide will ever draw. Owner, 2026-09-17: "no one
    /// ever needs 3k channels… note to the user if they try to add more than
    /// 300 they reached the limit." This is a *display* cap — the parser still
    /// ingests the whole playlist (see `AppleIPTVClient.maximumChannels`), so
    /// Search and the Custom package can still reach everything; the guide just
    /// stops at 300 and says so through `hiddenCount`.
    static let maximumDisplayedChannels = 300

    /// Whether one more channel may be added to a hand-picked selection
    /// (Custom package, or My Channels). Past the cap the guide would not draw
    /// it anyway, so Channel Manager refuses and says so rather than letting
    /// the viewer build a list the guide silently cuts.
    static func canAddChannel(toSelectionOf count: Int) -> Bool {
        count < maximumDisplayedChannels
    }

    /// The one line Channel Manager shows when a viewer tries to add past the cap.
    static let limitReachedMessage = "Limit reached — the guide shows up to \(maximumDisplayedChannels) channels."

    let channels: [AppleIPTVChannel]
    let channelIDs: [String]
    let categories: [String]
    /// How many selected channels the cap kept off the guide. Zero unless the
    /// selection exceeded `maximumDisplayedChannels`; the Live tab shows one
    /// line when it is not.
    let hiddenCount: Int

    init(channels: [AppleIPTVChannel], channelIDs: [String], categories: [String], hiddenCount: Int = 0) {
        self.channels = channels
        self.channelIDs = channelIDs
        self.categories = categories
        self.hiddenCount = hiddenCount
    }

    static func build(groups: [AppleIPTVChannelGroup], package: AppleLiveChannelPackage,
                      custom: AppleCustomChannelPackage, entries: [AppleChannelLineupEntry],
                      favoriteIDs: Set<String>, category: String) -> Self {
        let all = groups.flatMap(\.channels)
        let selected: [AppleIPTVChannel]
        switch package {
        case .custom: selected = custom.selected(from: all)
        case .everything: selected = all.filter { !AppleChannelVisibilityPolicy.isPlaceholder($0) }
        case .completeGuide: selected = AppleChannelVisibilityPolicy.deduplicatedEastChannels(all)
        }

        // One fuzzy match per channel, reused by the category list, the
        // category filter and the Complete Guide ordering. These were three
        // separate passes over the whole lineup — `categoryByID`, then
        // `completeGuideGroups` (which also re-deduplicated an already
        // deduplicated list), then the grouping below — and on the owner's
        // 9376 channels they cost **761 ms** of the Live tab's start-up
        // (measured 2026-09-15).
        #if DEBUG
        let matchCache = debugMatchCache ?? AppleLiveChannelMatchCache.shared
        #else
        let matchCache = AppleLiveChannelMatchCache.shared
        #endif
        let entryByChannelID = matchCache.match(channels: selected, entries: entries)

        var categoryByID = [String: String](minimumCapacity: selected.count)
        for (id, entry) in entryByChannelID {
            categoryByID[id] = entry.category == "Local" ? "Locals" : entry.category
        }
        // A channel the lineup does not know keeps the playlist's own group
        // (M3U `group-title`, Xtream category) when that group names one of
        // the guide's categories. Categories came from lineup matches only,
        // so a provider whose channels are not US networks (the fixture's
        // "News" / "Sports" panel, most foreign lists) showed All and
        // Favorites and nothing else (Apple TV full pass, 2026-10-02).
        for channel in selected where categoryByID[channel.id] == nil {
            if let category = AppleLiveCategoryPolicy.category(forPlaylistGroup: channel.group) {
                categoryByID[channel.id] = category
            }
        }
        let available = Set(categoryByID.values)
        let order = AppleLiveCategoryPolicy.order
        let categories = ["All", "Favorites"] + order.filter { available.contains($0) }
        let channels: [AppleIPTVChannel]
        if category == "All" {
            if package == .completeGuide {
                // Complete Guide is the curated lineup — not the lineup plus
                // everything that failed to match it. `completeGuideGroups`
                // also returns an "Other" group, and flattening both put the
                // whole provider list back into the guide: 4749 of the owner's
                // 9376 channels, where the phone shows a few hundred (owner
                // 2026-09-14: use the curated lineup on every platform).
                // Unmatched channels
                // stay reachable through Search and the Everything package.
                // Same ordering `completeGuideGroups` produced — one channel per
                // lineup number, by number then name — built from the matches
                // already in hand.
                var seenNumbers = Set<Int>()
                let numbered = selected.compactMap { channel -> (AppleChannelLineupEntry, AppleIPTVChannel)? in
                    guard let entry = entryByChannelID[channel.id],
                          seenNumbers.insert(entry.number).inserted else { return nil }
                    return (entry, channel)
                }.sorted {
                    $0.0.number == $1.0.number
                        ? $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending
                        : $0.0.number < $1.0.number
                }
                // The lineup only describes this source if it matched a
                // meaningful number of channels. This used to fall back only
                // when *nothing* matched, so a foreign M3U with one channel
                // that happened to share a name with the US lineup — "CNN",
                // say — showed exactly one channel under All. That is the
                // tester's "only one TV channel is displayed in M3U" (build
                // 10, 2026-09-17). Below the floor the curated list is not a
                // guide, it is a coincidence, and the viewer gets everything.
                channels = numbered.count < Self.minimumLineupMatches
                    ? selected
                    : numbered.map(\.1)
            } else {
                channels = Dictionary(grouping: selected) { entryByChannelID[$0.id]?.category ?? "Other" }
                    .sorted { $0.key < $1.key }.flatMap(\.value)
            }
        } else if category == "Favorites" {
            channels = selected.filter { favoriteIDs.contains($0.id) }
        } else {
            channels = selected.filter { categoryByID[$0.id] == category }
        }
        let shown = Array(channels.prefix(Self.maximumDisplayedChannels))
        return .init(channels: shown, channelIDs: shown.map(\.id), categories: categories,
                     hiddenCount: max(0, channels.count - shown.count))
    }
}

/// The guide's category chips, and how a playlist group reads as one of them.
enum AppleLiveCategoryPolicy {
    static let order = ["News", "Sports", "Entertainment", "Kids", "Movies", "Premium", "Lifestyle", "Music", "International", "Locals"]

    /// Keywords per chip, matched as whole words of the group name ("US| NEWS
    /// HD" is News). Groups that name no chip stay under All only, which keeps
    /// a panel with thousands of groups from flooding the chip row.
    private static let keywords: [(category: String, words: Set<String>)] = [
        ("News", ["news", "noticias", "nachrichten"]),
        ("Sports", ["sport", "sports", "deportes", "football", "soccer", "nfl", "nba", "nhl", "mlb"]),
        ("Kids", ["kids", "kid", "children", "cartoon", "cartoons", "family", "infantil"]),
        ("Movies", ["movie", "movies", "cinema", "film", "films", "cine"]),
        ("Music", ["music", "musica", "musique"]),
        ("Entertainment", ["entertainment", "general", "variety"]),
        ("Lifestyle", ["lifestyle", "documentary", "documentaries", "docs"]),
        ("Premium", ["premium"]),
        ("Locals", ["local", "locals"]),
        ("International", ["international", "world"]),
    ]

    static func category(forPlaylistGroup group: String) -> String? {
        let words = Set(group.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init))
        guard !words.isEmpty else { return nil }
        return keywords.first { !$0.words.isDisjoint(with: words) }?.category
    }
}
