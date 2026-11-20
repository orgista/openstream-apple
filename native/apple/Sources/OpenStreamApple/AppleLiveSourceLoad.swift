import Foundation

/// The Live tab's playlists as they answer. Every playlist is asked at once;
/// each one's channels go up as soon as it answers, in the order the viewer
/// added them, and one that fails shows its error inline (with Retry)
/// instead of holding up the rest. One dead IPTV
/// panel held the whole tab for ~35 s (iPad v2 re-run, 2026-10-01).
public struct AppleLiveSourceLoad: Sendable {
    public struct Failure: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let sourceName: String
        public let message: String
        /// The playlist's saved channels are still on screen. Its refresh
        /// failing is then not worth a word: the lineup works, and a channel
        /// that cannot be reached says so itself when it is played.
        public var showsSavedChannels = false

        /// The message, led by the playlist's name unless it already names it.
        public var text: String { message.contains(sourceName) ? message : "\(sourceName): \(message)" }
    }

    private let order: [UUID]
    private let names: [UUID: String]
    private let cached: [UUID: [AppleIPTVChannel]]
    private var loaded: [UUID: [AppleIPTVChannel]] = [:]
    private var failureMessages: [UUID: String] = [:]

    public init(sources: [AppleSource], cached: [UUID: [AppleIPTVChannel]] = [:]) {
        order = sources.map(\.id)
        names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        self.cached = cached
    }

    public mutating func succeeded(_ id: UUID, channels: [AppleIPTVChannel]) {
        loaded[id] = channels
        failureMessages[id] = nil
    }

    public mutating func failed(_ id: UUID, message: String) {
        failureMessages[id] = message
    }

    /// Fresh channels where a playlist answered, otherwise its saved copy,
    /// including during a failed refresh, in configured source order.
    public var channels: [AppleIPTVChannel] {
        order.flatMap { loaded[$0] ?? cached[$0] ?? [] }
    }

    /// Playlists that failed, in source order.
    public var failures: [Failure] {
        order.compactMap { id in
            failureMessages[id].map {
                Failure(id: id, sourceName: names[id] ?? "Playlist", message: $0,
                        showsSavedChannels: loaded[id] == nil && !(cached[id] ?? []).isEmpty)
            }
        }
    }

    /// Every playlist has answered, one way or the other.
    public var isComplete: Bool {
        unanswered.isEmpty
    }

    /// Playlists still being asked.
    public var unanswered: Set<UUID> {
        Set(order.filter { loaded[$0] == nil && failureMessages[$0] == nil })
    }

    /// `channels` holds every playlist: each has answered or has its saved copy up.
    public var isWhole: Bool {
        order.allSatisfy { loaded[$0] != nil || cached[$0] != nil || failureMessages[$0] != nil }
    }

    /// The merged lineup ready to go up, built off the main actor.
    struct Publication: Sendable {
        let index: AppleIPTVChannelIndex
        /// Chosen from a whole lineup only, so a playlist still out cannot
        /// drop its channels from the choice; nil without `packageEntries`.
        let package: AppleLiveChannelPackage?
    }

    /// `packageEntries` is the guide lineup the automatic package is chosen
    /// against, or nil when the viewer picked a package.
    func publication(packageEntries: [AppleChannelLineupEntry]?) async -> Publication {
        let load = self
        return await Task.detached(priority: .userInitiated) {
            let lineup = load.channels
            let package = load.isWhole ? packageEntries.map { AppleLiveChannelPackage.defaultPackage(for: lineup, entries: $0) } : nil
            return Publication(index: AppleIPTVChannelIndex(lineup), package: package)
        }.value
    }
}

extension AppleLiveSourceLoad {
    /// Asks every playlist at once and publishes after each answer; false when `answer` stopped the run.
    @MainActor
    static func collect<Request: Sendable>(
        _ requests: [Request],
        fetch: @escaping @Sendable (Request) async -> (AppleSource, Result<[AppleIPTVChannel], any Error>),
        answer: (AppleSource, Result<[AppleIPTVChannel], any Error>) async -> Bool,
        publish: () async -> Void
    ) async -> Bool {
        guard !requests.isEmpty else {
            await publish()
            return true
        }
        return await withTaskGroup(of: (AppleSource, Result<[AppleIPTVChannel], any Error>).self) { group in
            for request in requests {
                group.addTask { await fetch(request) }
            }
            for await (source, result) in group {
                guard await answer(source, result) else {
                    group.cancelAll()
                    return false
                }
                await publish()
            }
            return true
        }
    }
}
