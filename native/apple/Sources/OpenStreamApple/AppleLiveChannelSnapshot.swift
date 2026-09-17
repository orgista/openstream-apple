import Foundation

/// One immutable projection per lineup/filter change. SwiftUI reads these
/// arrays directly instead of normalizing every channel during each render.
struct AppleLiveChannelSnapshot: Sendable {
    /// How many lineup numbers the Premier Guide must match before All is
    /// allowed to show only the lineup.
    ///
    /// Eight is far below the owner's real provider (a few hundred of 9,376) and
    /// far above an accidental name collision (one or two), so it separates
    /// "this lineup describes this source" from "this lineup happens to share a
    /// channel name with it" with room on both sides.
    static let minimumLineupMatches = 8

    /// The group `AppleChannelProjection.premierGuideGroups` gives the curated
    /// lineup; anything it could not match lands in its sibling "Other" group.
    static let premierGroupName = "Premier Guide"

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
        case .premierGuide: selected = AppleChannelVisibilityPolicy.deduplicatedEastChannels(all)
        }
        let index = AppleChannelLineupIndex(entries)

        // One fuzzy match per channel, reused by the category list, the
        // category filter and the Premier Guide ordering. These were three
        // separate passes over the whole lineup — `categoryByID`, then
        // `premierGuideGroups` (which also re-deduplicated an already
        // deduplicated list), then the grouping below — and on the owner's
        // 9376 channels they cost **761 ms** of the Live tab's start-up
        // (measured 2026-09-15).
        var entryByChannelID = [String: AppleChannelLineupEntry](minimumCapacity: selected.count)
        for channel in selected where entryByChannelID[channel.id] == nil {
            if let entry = index.match(channel.name) { entryByChannelID[channel.id] = entry }
        }

        var categoryByID = [String: String](minimumCapacity: entryByChannelID.count)
        for (id, entry) in entryByChannelID {
            categoryByID[id] = entry.category == "Local" ? "Locals" : entry.category
        }
        let available = Set(categoryByID.values)
        let order = ["News", "Sports", "Entertainment", "Kids", "Movies", "Premium", "Lifestyle", "Music", "International", "Locals"]
        let categories = ["All", "Favorites"] + order.filter { available.contains($0) }
        let channels: [AppleIPTVChannel]
        if category == "All" {
            if package == .premierGuide {
                // Premier Guide is the curated lineup — not the lineup plus
                // everything that failed to match it. `premierGuideGroups`
                // also returns an "Other" group, and flattening both put the
                // whole provider list back into the guide: 4749 of the owner's
                // 9376 channels, where the phone shows a few hundred (owner
                // 2026-09-14: "reduce the live line up to the premier safe
                // thing we did with iPhone and android"). Unmatched channels
                // stay reachable through Search and the Everything package.
                // Same ordering `premierGuideGroups` produced — one channel per
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
