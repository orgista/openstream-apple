import Foundation

struct AppleGuideChannel: Identifiable, Equatable, Sendable {
    let channel: AppleIPTVChannel
    let number: Int?
    var id: String { channel.id }
}

enum AppleGuideChannelProjection {
    static func rows(channels: [AppleIPTVChannel], entries: [AppleChannelLineupEntry],
                     favoriteIDs: Set<String>, favoritesOnly: Bool, sortByNumber: Bool) -> [AppleGuideChannel] {
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
            return AppleGuideChannel(channel: channel, number: lookup[AppleChannelLineupPresets.normalize(name: channel.name)])
        }
        return rows.sorted {
            if sortByNumber, $0.number != $1.number { return ($0.number ?? .max) < ($1.number ?? .max) }
            let comparison = $0.channel.name.localizedStandardCompare($1.channel.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    static func window(day: Date, now: Date, calendar: Calendar = .current) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86400)
        let start: Date
        if calendar.isDate(day, inSameDayAs: now) {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            var rounded = components
            rounded.minute = ((components.minute ?? 0) / 30) * 30
            start = calendar.date(from: rounded) ?? now
        } else {
            start = startOfDay
        }
        return DateInterval(start: start, end: nextDay)
    }
}
