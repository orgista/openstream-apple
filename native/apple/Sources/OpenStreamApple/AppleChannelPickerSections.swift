import Foundation

/// How "Add Channels…" lays a lineup out: grouped by the provider's group
/// while browsing, one flat "Results" section while searching. Pure, so a
/// 5,000-channel lineup can be checked without a view.
public enum AppleChannelPickerSections {
    public struct Section: Identifiable, Equatable, Sendable {
        public let name: String
        public let channels: [AppleIPTVChannel]
        public var id: String { name }
    }

    public static let ungroupedName = "Other"
    public static let resultsName = "Results"

    public static func build(channels: [AppleIPTVChannel], query: String) -> [Section] {
        guard !channels.isEmpty else { return [] }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [Section(name: resultsName, channels: channels)]
        }
        var order: [String] = []
        var byGroup: [String: [AppleIPTVChannel]] = [:]
        for channel in channels {
            let name = channel.group.isEmpty ? ungroupedName : channel.group
            if byGroup[name] == nil { order.append(name) }
            byGroup[name, default: []].append(channel)
        }
        let named = order.filter { $0 != ungroupedName }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let ordered = named + (byGroup[ungroupedName] == nil ? [] : [ungroupedName])
        return ordered.map { Section(name: $0, channels: byGroup[$0] ?? []) }
    }
}
