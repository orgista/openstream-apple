import Foundation

public enum AppleLiveChannelPreferences {
    public static func groupKey(_ channel: AppleIPTVChannel) -> String {
        channel.sourceID.uuidString + ":" + channel.group
    }

    public static func visible(_ channels: [AppleIPTVChannel], hiddenIDs: Set<String>, hiddenGroups: Set<String>) -> [AppleIPTVChannel] {
        channels.filter { !hiddenIDs.contains($0.id) && !hiddenGroups.contains(groupKey($0)) }
    }

    public static func order(_ saved: [String], favoriteIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        let retained = saved.filter { favoriteIDs.contains($0) && seen.insert($0).inserted }
        return retained + favoriteIDs.subtracting(seen).sorted()
    }
}
