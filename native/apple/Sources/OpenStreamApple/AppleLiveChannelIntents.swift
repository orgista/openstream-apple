import AppIntents
import Foundation

public struct OpenStreamChannelEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "oStream Channel"
    public static let defaultQuery = OpenStreamChannelQuery()
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
    public var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

public struct OpenStreamChannelQuery: EntityStringQuery {
    public init() {}

    private func available() -> [OpenStreamChannelEntity] {
        guard AppleSettingsStore.topShelfEnabled(),
              let snapshot = AppleTopShelfSnapshotReader().read() else { return [] }
        var seen: Set<String> = []
        return (snapshot.favoriteChannels + snapshot.recentChannels).compactMap { item in
            guard seen.insert(item.id).inserted, AppleAppRoute.liveURL(channelID: item.id) != nil else { return nil }
            return .init(id: item.id, name: item.title)
        }
    }

    public func entities(for identifiers: [String]) async throws -> [OpenStreamChannelEntity] {
        let wanted = Set(identifiers)
        return available().filter { wanted.contains($0.id) }
    }

    public func entities(matching string: String) async throws -> [OpenStreamChannelEntity] {
        available().filter { $0.name.localizedStandardContains(string) }
    }

    public func suggestedEntities() async throws -> [OpenStreamChannelEntity] { available() }
}

public struct WatchOpenStreamChannelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Watch Channel in oStream"
    public static let openAppWhenRun = true
    @Parameter(title: "Channel") public var channel: OpenStreamChannelEntity
    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let selected = try await OpenStreamChannelQuery().entities(for: [channel.id]).first else {
            throw ChannelUnavailable.unavailable
        }
        await AppleAppIntentHandoff.shared.send(.live(channelID: selected.id))
        return .result()
    }

    private enum ChannelUnavailable: LocalizedError {
        case unavailable
        var errorDescription: String? { "This channel is no longer available in oStream." }
    }
}
