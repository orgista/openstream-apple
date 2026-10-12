/// A loaded lineup and its lookup table travel together, so replacing or
/// clearing a source cannot leave stale focus/last-watched lookups behind.
struct AppleIPTVChannelIndex: Sendable {
    let channels: [AppleIPTVChannel]
    private let channelsByID: [String: AppleIPTVChannel]

    init(_ channels: [AppleIPTVChannel]) {
        self.channels = channels
        // Match the previous first(where:) behavior if sources contain a
        // duplicate id; Dictionary(uniqueKeysWithValues:) would trap.
        channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(id: String) -> AppleIPTVChannel? { channelsByID[id] }
}
