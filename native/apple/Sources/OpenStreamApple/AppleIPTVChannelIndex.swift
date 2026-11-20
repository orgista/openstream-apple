import Foundation

/// A loaded lineup and its lookup table travel together, so replacing or
/// clearing a source cannot leave stale focus/last-watched lookups behind.
///
/// Equal only to itself (and its copies): SwiftUI compares a view's inputs
/// on the main thread, and a lineup of thousands must not be compared channel
/// by channel there. A rebuilt index is a new value even with the same channels.
struct AppleIPTVChannelIndex: Sendable, Equatable {
    let channels: [AppleIPTVChannel]
    private let channelsByID: [String: AppleIPTVChannel]
    private let identity = UUID()

    init(_ channels: [AppleIPTVChannel]) {
        self.channels = channels
        // A duplicate id resolves to its first channel, as
        // `channels.first(where:)` does; Dictionary(uniqueKeysWithValues:) would trap.
        channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(id: String) -> AppleIPTVChannel? { channelsByID[id] }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}
