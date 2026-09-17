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
