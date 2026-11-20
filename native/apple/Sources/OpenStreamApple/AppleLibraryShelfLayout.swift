import Foundation

/// Which Library shelf carries the sort control.
///
/// The old rule was "the first kind of the **first source**". That quietly
/// loses the control altogether: `library.sources` is every enabled library and
/// NAS source, and the first of them may draw no shelves at all — an offline
/// NAS, or one whose titles are all filtered out. Every later shelf then failed
/// the `source == sources.first` test, so no shelf carried the sort menu and
/// the viewer had no way to change the order.
///
/// The control belongs on the first shelf that is actually **drawn**.
public enum AppleLibraryShelfLayout {
    /// Home rails stay bounded; their heading opens the complete library list.
    public static func preview<Title>(_ titles: [Title]) -> [Title] {
        Array(titles.prefix(24))
    }

    /// Given, per source and in display order, the kinds that source will draw,
    /// returns which shelf carries the accessory.
    public static func accessoryShelf(
        sourcesWithKinds: [[String]]
    ) -> (sourceIndex: Int, kind: String)? {
        for (index, kinds) in sourcesWithKinds.enumerated() {
            if let kind = kinds.first { return (index, kind) }
        }
        return nil
    }
}

/// Library's Recently Added row and its Movies / Shows rows without the same
/// posters twice (test Apple TV walk b20r18: with the default Added sort, Movies led
/// with exactly the titles Recently Added drew below it).
///
/// Plex and Infuse do it the same way: Recently Added is its own row at the
/// top, and the kind rows carry the rest of the library. A kind row's full
/// list ("See All") still holds every title of that kind.
extension AppleLibraryShelfLayout {
    /// The newest titles for Recently Added, or none when the whole library
    /// fits in that row — the kind rows already show all of it then.
    public static func recentlyAdded<Title>(newestFirst titles: [Title], limit: Int) -> [Title] {
        titles.count > limit ? Array(titles.prefix(limit)) : []
    }

    /// A kind row's titles minus the ones Recently Added already draws. Empty
    /// means the row is skipped: every title of that kind is in Recently Added.
    public static func row<Title: Identifiable>(_ titles: [Title], excluding recent: [Title]) -> [Title] {
        guard !recent.isEmpty else { return titles }
        let drawn = Set(recent.map(\.id))
        return titles.filter { !drawn.contains($0.id) }
    }
}
