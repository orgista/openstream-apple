import Foundation

/// The Live tab's category row on iPhone and iPad: All, Favorites (only with
/// a favourite), Events (pay-per-view, only when the lineup has some), then
/// the lineup's groups in the guide's order. Events is where pay-per-view
/// lives (owner item 11); it shows even with "Show pay-per-view" off, since
/// the tab itself is the opt-in.
enum AppleLiveCategoryOrder {
    static let all = "All"
    static let favorites = "Favorites"
    static let events = "Events"

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

    /// Pay-per-view channels for the Events tab, by name.
    static func eventChannels(_ channels: [AppleIPTVChannel]) -> [AppleIPTVChannel] {
        channels.filter(AppleChannelVisibilityPolicy.isPayPerView)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
