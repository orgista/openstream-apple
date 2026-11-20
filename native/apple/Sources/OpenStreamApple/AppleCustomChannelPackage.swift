import Foundation

public struct AppleCustomChannelPackage: Codable, Equatable, Sendable {
    public var channels: [String: Bool] = [:]
    public var groups: [String: Bool] = [:]
    public var includeWestFeeds = false
    public init() {}

    var identity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { ApplePlaybackIdentity.digest(for: String(decoding: $0, as: UTF8.self)) } ?? ""
    }

    func selected(from values: [AppleIPTVChannel], entries: [AppleChannelLineupEntry] = AppleChannelLineupPresets.current) -> [AppleIPTVChannel] {
        let base = Set(AppleChannelProjection.completeGuideGroups(from: values, entries: entries).flatMap(\.channels)
            .filter { !AppleChannelVisibilityPolicy.isPlaceholder($0) && !AppleChannelVisibilityPolicy.is24x7($0)
                && !AppleChannelVisibilityPolicy.isWestFeed($0) }.map(\.id))
        return values.filter { channel in
            guard groups[channel.group] != false else { return false }
            if let included = channels[channel.id] { return included }
            let west = AppleChannelVisibilityPolicy.isWestFeed(channel)
            return base.contains(channel.id) || (includeWestFeeds && west && !AppleChannelVisibilityPolicy.isPlaceholder(channel))
        }
    }
}
