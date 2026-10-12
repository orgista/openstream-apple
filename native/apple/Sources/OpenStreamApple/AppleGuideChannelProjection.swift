import Foundation

struct AppleGuideChannel: Identifiable, Equatable, Sendable {
    let channel: AppleIPTVChannel
    let number: Int?
    var id: String { channel.id }
}

enum AppleGuideChannelProjection {
    static func rows(channels: [AppleIPTVChannel], entries: [AppleChannelLineupEntry],
                     favoriteIDs: Set<String>, favoritesOnly: Bool, sortByNumber: Bool, favoriteOrder: [String] = []) -> [AppleGuideChannel] {
        // Normalize the small lineup once, not every entry in every comparison
        // of a several-thousand-channel sort on the main actor.
        var lookup: [String: Int] = [:]
        for entry in entries {
            for name in [entry.name] + entry.aliases {
                let key = AppleChannelLineupPresets.normalize(name: name)
                if lookup[key] == nil { lookup[key] = entry.number }
            }
        }
        var seen = Set<String>()
        let rows = channels.compactMap { channel -> AppleGuideChannel? in
            guard seen.insert(channel.id).inserted,
                  !favoritesOnly || favoriteIDs.contains(channel.id) else { return nil }
            // The curated lineup's number first (it is what the Complete Guide
            // is ordered by), then the playlist's own (`tvg-chno` / Xtream
            // `num`). Only the lineup was ever read, so a provider list showed
            // logo and name with no number at all (Apple TV pass, 2026-10-02).
            let number = lookup[AppleChannelLineupPresets.normalize(name: channel.name)] ?? channel.channelNumber
            return AppleGuideChannel(channel: channel, number: number)
        }
        let order = AppleLiveChannelPreferences.order(favoriteOrder, favoriteIDs: favoriteIDs)
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return rows.sorted {
            if !favoriteOrder.isEmpty, ranks[$0.id] != ranks[$1.id] { return (ranks[$0.id] ?? .max) < (ranks[$1.id] ?? .max) }
            if sortByNumber, $0.number != $1.number { return ($0.number ?? .max) < ($1.number ?? .max) }
            let comparison = $0.channel.name.localizedStandardCompare($1.channel.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// - Parameter earliest: how far back the guide may scroll for channels
    ///   with catch-up (`AppleIPTVCatchUp.earliestGuideTime`); the window then
    ///   opens on that half hour instead of the current one.
    static func window(day: Date, now: Date, calendar: Calendar = .current, earliest: Date? = nil) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86400)
        let start: Date
        if calendar.isDate(day, inSameDayAs: now) {
            start = halfHour(of: min(now, earliest ?? now), calendar: calendar)
        } else {
            start = startOfDay
        }
        return DateInterval(start: start, end: nextDay)
    }

    /// `date` rounded down to the half hour.
    static func halfHour(of date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var rounded = components
        rounded.minute = ((components.minute ?? 0) / 30) * 30
        return calendar.date(from: rounded) ?? date
    }
}
