import AppIntents
import Foundation
import Observation

#if canImport(CoreSpotlight) && !os(tvOS)
import CoreSpotlight
#endif

public struct OpenStreamMediaEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "OpenStream Media"
    public static let defaultQuery = OpenStreamMediaQuery()

    public let id: String
    public let title: String
    public let kind: String
    public let year: Int?

    public init(record: AppleMediaRecord) {
        id = record.id
        title = record.title
        kind = record.kind.rawValue.capitalized
        year = record.year
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind)\(year.map { " · \($0)" } ?? "")"
        )
    }
}

public struct OpenStreamMediaQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [OpenStreamMediaEntity.ID]) async throws -> [OpenStreamMediaEntity] {
        guard systemDiscoveryEnabled else { return [] }
        let wanted = Set(identifiers)
        return await repository.records()
            .filter { wanted.contains($0.id) && !$0.isPrivate && !$0.availability.isEmpty }
            .map(OpenStreamMediaEntity.init)
    }

    public func entities(matching string: String) async throws -> [OpenStreamMediaEntity] {
        guard systemDiscoveryEnabled else { return [] }
        return await repository.search(string, limit: 25, eligibility: .systemDiscovery)
            .map(OpenStreamMediaEntity.init)
    }

    public func suggestedEntities() async throws -> [OpenStreamMediaEntity] {
        guard systemDiscoveryEnabled else { return [] }
        return await repository.records()
            .filter { !$0.isPrivate && !$0.availability.isEmpty && ($0.isFavorite || $0.progress != nil) }
            .prefix(25)
            .map(OpenStreamMediaEntity.init)
    }

    private var repository: AppleMediaIndexRepository { AppleMediaIndexRepository() }
    private var systemDiscoveryEnabled: Bool {
        UserDefaults.standard.bool(forKey: "openstream.settings.privacy.systemSearch.v1")
    }
}

#if canImport(CoreSpotlight) && !os(tvOS)
extension OpenStreamMediaEntity: IndexedEntity {
    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = [kind, year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return attributes
    }
}
#endif

@MainActor
@Observable
public final class AppleAppIntentHandoff {
    public static let shared = AppleAppIntentHandoff()
    public private(set) var route: AppleAppRoute?
    public private(set) var revision = 0

    private init() {}

    public func send(_ route: AppleAppRoute) {
        self.route = route
        revision &+= 1
    }
}

public struct SearchOpenStreamIntent: ShowInAppSearchResultsIntent {
    public static let title: LocalizedStringResource = "Search OpenStream"
    public static let description = IntentDescription("Search content from sources you added to OpenStream.")
    public static let searchScopes: [StringSearchScope] = [.general, .movies, .tv]

    @Parameter(title: "Search")
    public var criteria: StringSearchCriteria

    public init() { criteria = .init(term: "") }

    public func perform() async throws -> some IntentResult {
        let term = String(criteria.term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !term.isEmpty else { return .result() }
        await AppleAppIntentHandoff.shared.send(.search(term))
        return .result()
    }
}

public struct PlayOpenStreamVideoIntent: PlayVideoIntent {
    public static let title: LocalizedStringResource = "Play in OpenStream"
    public static let description = IntentDescription("Find a movie or show in OpenStream and open the safe playback route.")
    public static let supportedCategories: [VideoCategory] = [.movies, .tv]

    @Parameter(title: "Title")
    public var term: String

    public init() { term = "" }

    public func perform() async throws -> some IntentResult {
        let clean = String(term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty else { return .result() }
        let matches = await AppleMediaIndexRepository().search(clean, limit: 100, eligibility: .playableVideo)
            .prefix(3)
        let exact = matches.filter { $0.title.caseInsensitiveCompare(clean) == .orderedSame }
        if exact.count == 1, let record = exact.first, record.availability.count == 1 {
            await AppleAppIntentHandoff.shared.send(.media(id: record.id, action: .play))
        } else {
            await AppleAppIntentHandoff.shared.send(.search(clean))
        }
        return .result()
    }
}

public struct OpenOpenStreamMediaIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open OpenStream Media"
    public static let description = IntentDescription("Open one indexed title in OpenStream.")
    public static let openAppWhenRun = true

    @Parameter(title: "Media")
    public var media: OpenStreamMediaEntity

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppleAppIntentHandoff.shared.send(.media(id: media.id, action: .display))
        return .result()
    }
}

public struct ContinueWatchingOpenStreamIntent: AppIntent {
    public static let title: LocalizedStringResource = "Continue Watching in OpenStream"
    public static let description = IntentDescription("Open Continue Watching in OpenStream.")
    public static let openAppWhenRun = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppleAppIntentHandoff.shared.send(.continueWatching)
        return .result()
    }
}

public struct OpenStreamShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchOpenStreamIntent(),
            phrases: ["Search with \(.applicationName)"],
            shortTitle: "Search OpenStream",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlayOpenStreamVideoIntent(),
            phrases: ["Play a video with \(.applicationName)"],
            shortTitle: "Play in OpenStream",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ContinueWatchingOpenStreamIntent(),
            phrases: ["Continue watching in \(.applicationName)"],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
    }
}
