import Foundation

/// The Live tab's category row on iPhone and iPad: All, Favorites (only with
/// a favourite), Pay-Per-View (only when the lineup has some), then the
/// lineup's groups in the guide's order. It shows even with "Show
/// Pay-Per-View" off, since the tab itself is the opt-in (owner item 11). It
/// was called Events, and the owner could not find it (recording 2026-10-15:
/// "I don't even know where pay-per-view is").
enum AppleLiveCategoryOrder {
    static let all = "All"
    static let favorites = "Favorites"
    static let events = "Pay-Per-View"

    static func tabs(groups: [String], hasFavorites: Bool, eventCount: Int) -> [String] {
        var tabs = [all]
        if hasFavorites { tabs.append(favorites) }
        if eventCount > 0 { tabs.append(events) }
        let fixed = Set([all, favorites, events])
        var seen = Set<String>()
        for group in groups where !fixed.contains(group) && seen.insert(group).inserted {
            tabs.append(group)
        }
        return tabs
    }

    /// The tab to show after the row changes: the same one while it still
    /// exists, otherwise All (the last favourite removed, events gone).
    static func resolved(_ selected: String, in tabs: [String]) -> String {
        tabs.contains(selected) ? selected : all
    }

    /// Pay-per-view channels by name, without the provider's empty slots ("EVENTS 24:").
    static func eventChannels(_ channels: [AppleIPTVChannel]) -> [AppleIPTVChannel] {
        channels.filter { channel in
            AppleChannelVisibilityPolicy.isPayPerView(channel) && !AppleChannelVisibilityPolicy.isPlaceholder(channel)
                && !channel.name.trimmingCharacters(in: .whitespaces).hasSuffix(":")
        }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
