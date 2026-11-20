import Foundation
import Synchronization

private enum AppleMediaServerDate {
    private static let fractional = Mutex(formatter(fractionalSeconds: true))
    private static let seconds = Mutex(formatter(fractionalSeconds: false))

    static func date(from value: String) -> Date? {
        fractional.withLock { $0.date(from: value) } ?? seconds.withLock { $0.date(from: value) }
    }

    static func string(from date: Date) -> String {
        fractional.withLock { $0.string(from: date) }
    }

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}

public struct AppleMediaServerLibrary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let collectionType: Kind
    
    public enum Kind: String, Codable, Equatable, Sendable {
        case movies
        case tvshows
        case collections = "boxsets"
        case other
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let str = try container.decodeIfPresent(String.self, forKey: .collectionType),
           let kind = Kind(rawValue: str.lowercased()) {
            collectionType = kind
        } else {
            collectionType = .other
        }
    }
    
    public init(id: String, name: String, collectionType: Kind) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(collectionType.rawValue, forKey: .collectionType)
    }
}

public enum AppleMediaServerItemType: String, Codable, Hashable, Sendable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case other
}

public struct AppleMediaServerItem: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: AppleMediaServerItemType
    public let year: Int?
    public let addedAt: Date?
    public let overview: String?
    public let runtimeSeconds: Double?
    public let seriesID: String?
    public let seriesName: String?
    public let seasonID: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let primaryImageTag: String?
    public let logoImageTag: String?
    public let backdropImageTags: [String]
    public let providerIDs: [String: String]
    public let communityRating: Double?
    public let genres: [String]
    public private(set) var userData: UserData?
    public var officialRating: String? = nil
    public var tagline: String? = nil
    public var people: [Person] = []
    public var remoteTrailers: [RemoteTrailer] = []
    /// The series' poster, for an episode or season without its own.
    public var seriesPrimaryImageTag: String? = nil
    /// The item that holds the backdrop when this one has none (an episode's series).
    public var parentBackdropItemID: String? = nil
    public var parentBackdropImageTags: [String] = []

    public struct Person: Codable, Equatable, Sendable {
        public let id: String?
        public let name: String
        /// "Actor", "Director", "Writer", "Producer", "GuestStar"…
        public let type: String?
        public let role: String?
        public let primaryImageTag: String?

        private enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", role = "Role", primaryImageTag = "PrimaryImageTag"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            // Servers send "" for an actor whose character is not known.
            role = (try? container.decodeIfPresent(String.self, forKey: .role))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            primaryImageTag = try? container.decodeIfPresent(String.self, forKey: .primaryImageTag)
        }

        public init(id: String? = nil, name: String, type: String? = nil, role: String? = nil, primaryImageTag: String? = nil) {
            self.id = id
            self.name = name
            self.type = type
            self.role = role
            self.primaryImageTag = primaryImageTag
        }
    }

    public struct RemoteTrailer: Codable, Equatable, Sendable {
        public let url: String
        public let name: String?

        private enum CodingKeys: String, CodingKey { case url = "Url", name = "Name" }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
        }

        public init(url: String, name: String? = nil) {
            self.url = url
            self.name = name
        }
    }
    
    public struct UserData: Codable, Equatable, Sendable {
        public let positionSeconds: Double
        public let played: Bool
        public let isFavorite: Bool
        public let playCount: Int
        public let lastPlayedDate: Date?
        
        private enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case played = "Played"
            case isFavorite = "IsFavorite"
            case playCount = "PlayCount"
            case lastPlayedDate = "LastPlayedDate"
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let ticks = container.lenientInt64(forKey: .playbackPositionTicks) ?? 0
            positionSeconds = AppleMediaServerTicks.seconds(fromTicks: ticks)
            played = (try? container.decodeIfPresent(Bool.self, forKey: .played)) ?? false
            isFavorite = (try? container.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? false
            playCount = container.lenientInt(forKey: .playCount) ?? 0
            if let value = try? container.decodeIfPresent(String.self, forKey: .lastPlayedDate) {
                lastPlayedDate = AppleMediaServerDate.date(from: value)
            } else {
                lastPlayedDate = nil
            }
        }
        
        public init(positionSeconds: Double = 0, played: Bool = false, isFavorite: Bool = false, playCount: Int = 0, lastPlayedDate: Date? = nil) {
            self.positionSeconds = positionSeconds
            self.played = played
            self.isFavorite = isFavorite
            self.playCount = playCount
            self.lastPlayedDate = lastPlayedDate
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(AppleMediaServerTicks.ticks(fromSeconds: positionSeconds), forKey: .playbackPositionTicks)
            try container.encode(played, forKey: .played)
            try container.encode(isFavorite, forKey: .isFavorite)
            try container.encode(playCount, forKey: .playCount)
            if let lastPlayedDate {
                try container.encode(AppleMediaServerDate.string(from: lastPlayedDate), forKey: .lastPlayedDate)
            }
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case year = "ProductionYear"
        case addedAt = "DateCreated"
        case overview = "Overview"
        case runTimeTicks = "RunTimeTicks"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case seasonID = "SeasonId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case providerIDs = "ProviderIds"
        case communityRating = "CommunityRating"
        case genres = "Genres"
        case userData = "UserData"
        case officialRating = "OfficialRating"
        case taglines = "Taglines"
        case people = "People"
        case remoteTrailers = "RemoteTrailers"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
    }
    
    /// Only the id is required. Every other field that comes in an
    /// unexpected shape is dropped on its own, so one odd field never costs
    /// the item, and one odd item never costs the page.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decodeIfPresent(String.self, forKey: .type))
            .flatMap(AppleMediaServerItemType.init(rawValue:)) ?? .other
        year = container.lenientInt(forKey: .year)
        if let value = try? container.decodeIfPresent(String.self, forKey: .addedAt) {
            addedAt = AppleMediaServerDate.date(from: value)
        } else {
            addedAt = nil
        }
        overview = try? container.decodeIfPresent(String.self, forKey: .overview)
        runtimeSeconds = container.lenientInt64(forKey: .runTimeTicks).map(AppleMediaServerTicks.seconds(fromTicks:))
        seriesID = try? container.decodeIfPresent(String.self, forKey: .seriesID)
        seriesName = try? container.decodeIfPresent(String.self, forKey: .seriesName)
        seasonID = try? container.decodeIfPresent(String.self, forKey: .seasonID)
        indexNumber = container.lenientInt(forKey: .indexNumber)
        parentIndexNumber = container.lenientInt(forKey: .parentIndexNumber)
        // A season or episode without a name is called by its number; any
        // other item without one stays nameless and is left off the shelves
        // (`AppleMediaServerLibraryStore.isEligible`).
        let sentName = (try? container.decodeIfPresent(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (type, indexNumber) {
        case _ where !sentName.isEmpty: name = sentName
        case (.season, 0): name = "Specials"
        case (.season, let number?): name = "Season \(number)"
        case (.episode, let number?): name = "Episode \(number)"
        default: name = ""
        }
        
        let imageTags = (try? container.decodeIfPresent([String: String].self, forKey: .imageTags)) ?? [:]
        primaryImageTag = imageTags["Primary"]
        logoImageTag = imageTags["Logo"]
        
        backdropImageTags = (try? container.decodeIfPresent([String].self, forKey: .backdropImageTags)) ?? []
        providerIDs = (try? container.decodeIfPresent([String: String].self, forKey: .providerIDs)) ?? [:]
        // 0 is how some servers say "not rated".
        communityRating = (try? container.decodeIfPresent(Double.self, forKey: .communityRating)).flatMap { $0 > 0 ? $0 : nil }
        genres = (try? container.decodeIfPresent([String].self, forKey: .genres)) ?? []
        userData = try? container.decodeIfPresent(UserData.self, forKey: .userData)
        officialRating = try? container.decodeIfPresent(String.self, forKey: .officialRating)
        tagline = (try? container.decodeIfPresent([String].self, forKey: .taglines))?.first
        people = (try? container.decodeIfPresent(AppleLossyArray<Person>.self, forKey: .people))?.values ?? []
        remoteTrailers = (try? container.decodeIfPresent(AppleLossyArray<RemoteTrailer>.self, forKey: .remoteTrailers))?.values ?? []
        seriesPrimaryImageTag = try? container.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag)
        parentBackdropItemID = try? container.decodeIfPresent(String.self, forKey: .parentBackdropItemID)
        parentBackdropImageTags = (try? container.decodeIfPresent([String].self, forKey: .parentBackdropImageTags)) ?? []
    }
    
    public init(id: String, name: String, type: AppleMediaServerItemType, year: Int? = nil, overview: String? = nil, runtimeSeconds: Double? = nil, seriesID: String? = nil, seriesName: String? = nil, seasonID: String? = nil, indexNumber: Int? = nil, parentIndexNumber: Int? = nil, primaryImageTag: String? = nil, logoImageTag: String? = nil, backdropImageTags: [String] = [], providerIDs: [String: String] = [:], communityRating: Double? = nil, genres: [String] = [], userData: UserData? = nil, addedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.year = year
        self.addedAt = addedAt
        self.overview = overview
        self.runtimeSeconds = runtimeSeconds
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.seasonID = seasonID
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.primaryImageTag = primaryImageTag
        self.logoImageTag = logoImageTag
        self.backdropImageTags = backdropImageTags
        self.providerIDs = providerIDs
        self.communityRating = communityRating
        self.genres = genres
        self.userData = userData
    }
    
    /// Seasons and episodes by their numbers, Specials (season 0) after the
    /// numbered seasons; unnumbered ones keep their server order at the end.
    static func inIndexOrder(_ items: [AppleMediaServerItem]) -> [AppleMediaServerItem] {
        func key(_ item: AppleMediaServerItem, _ offset: Int) -> (Int, Int, Int) {
            let season = item.type == .season ? item.indexNumber : item.parentIndexNumber
            return (season == 0 ? .max - 1 : season ?? .max, item.indexNumber ?? .max, offset)
        }
        return items.enumerated().sorted { key($0.element, $0.offset) < key($1.element, $1.offset) }.map(\.element)
    }

    public var imdbID: String? {
        providerIDs.first { $0.key.caseInsensitiveCompare("Imdb") == .orderedSame }?.value
    }
    
    public var tmdbID: String? {
        providerIDs.first { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame }?.value
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(year, forKey: .year)
        if let addedAt {
            try container.encode(AppleMediaServerDate.string(from: addedAt), forKey: .addedAt)
        }
        try container.encodeIfPresent(overview, forKey: .overview)
        if let sec = runtimeSeconds {
            try container.encode(AppleMediaServerTicks.ticks(fromSeconds: sec), forKey: .runTimeTicks)
        }
        try container.encodeIfPresent(seriesID, forKey: .seriesID)
        try container.encodeIfPresent(seriesName, forKey: .seriesName)
        try container.encodeIfPresent(seasonID, forKey: .seasonID)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        
        var tags: [String: String] = [:]
        if let p = primaryImageTag { tags["Primary"] = p }
        if let l = logoImageTag { tags["Logo"] = l }
        if !tags.isEmpty {
            try container.encode(tags, forKey: .imageTags)
        }
        
        try container.encode(backdropImageTags, forKey: .backdropImageTags)
        try container.encode(providerIDs, forKey: .providerIDs)
        try container.encodeIfPresent(communityRating, forKey: .communityRating)
        try container.encode(genres, forKey: .genres)
        try container.encodeIfPresent(userData, forKey: .userData)
        try container.encodeIfPresent(officialRating, forKey: .officialRating)
        try container.encodeIfPresent(tagline.map { [$0] }, forKey: .taglines)
        if !people.isEmpty { try container.encode(people, forKey: .people) }
        if !remoteTrailers.isEmpty { try container.encode(remoteTrailers, forKey: .remoteTrailers) }
        try container.encodeIfPresent(seriesPrimaryImageTag, forKey: .seriesPrimaryImageTag)
        try container.encodeIfPresent(parentBackdropItemID, forKey: .parentBackdropItemID)
        if !parentBackdropImageTags.isEmpty { try container.encode(parentBackdropImageTags, forKey: .parentBackdropImageTags) }
    }
}

extension AppleMediaServerItem {
    /// The same item with new viewer state (position, played, favourite, play count).
    public func withUserData(_ userData: UserData?) -> AppleMediaServerItem {
        var copy = self
        copy.userData = userData
        return copy
    }
}

/// An array whose elements decode one by one: an element in a shape the app
/// does not understand is skipped instead of failing the whole reply.
struct AppleLossyArray<Element: Decodable>: Decodable {
    let values: [Element]
    /// Entries in the reply, the skipped ones included.
    let receivedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            if let value = try? Element(from: entry) { result.append(value) }
        }
        values = result
        receivedCount = container.currentIndex
    }
}

/// The `Items` list Jellyfin and Emby wrap their lists in.
struct AppleMediaServerItemList<Element: Decodable>: Decodable {
    let items: [Element]
    let receivedCount: Int
    private enum CodingKeys: String, CodingKey { case items = "Items" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decodeIfPresent(AppleLossyArray<Element>.self, forKey: .items)
        items = list?.values ?? []
        receivedCount = list?.receivedCount ?? 0
    }
}

extension KeyedDecodingContainer {
    /// A whole number sent as a number or as a numeric string; nil otherwise.
    func lenientInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           abs(value) < 9.2e18 { return Int64(value) }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientInt(forKey key: Key) -> Int? {
        lenientInt64(forKey: key).flatMap { Int(exactly: $0) }
    }
}

public struct AppleMediaServerItemPage: Codable, Equatable, Sendable {
    public let items: [AppleMediaServerItem]
    public let totalRecordCount: Int
    /// Entries the server sent, unreadable ones included: the next page
    /// starts after all of them.
    public let receivedCount: Int
    
    private enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decodeIfPresent(AppleLossyArray<AppleMediaServerItem>.self, forKey: .items)
        items = list?.values ?? []
        receivedCount = list?.receivedCount ?? 0
        totalRecordCount = container.lenientInt(forKey: .totalRecordCount) ?? receivedCount
    }
    
    public init(items: [AppleMediaServerItem], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        receivedCount = items.count
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(totalRecordCount, forKey: .totalRecordCount)
    }
}

public struct AppleMediaServerPlaybackInfo: Codable, Equatable, Sendable {
    public let playSessionID: String?
    public let mediaSources: [MediaSource]
    public var defaultMediaSourceID: String? = nil
    /// Why the server offers nothing to play ("NoCompatibleStream",
    /// "NotAllowed", "RateLimitExceeded"), when it says.
    public var errorCode: String? = nil
    
    public struct MediaSource: Codable, Equatable, Sendable {
        public let id: String
        public let container: String?
        public let supportsDirectPlay: Bool
        public let supportsDirectStream: Bool
        public let transcodingURLPath: String?
        public let directStreamURLPath: String?
        public let name: String?
        public var size: Int64? = nil
        public var runtimeTicks: Int64? = nil
        public var bitrate: Int? = nil
        public var mediaStreams: [MediaStream] = []
        /// Where the server reads the media: a file path, or an http(s) URL
        /// for a source the server does not hold itself.
        public var path: String? = nil
        /// "File", "Http", "Rtmp"…
        public var protocolName: String? = nil
        /// "Default", "Grouping", or "Placeholder".
        public var sourceType: String? = nil
        public var isRemote: Bool = false
        /// Headers the server says a direct request to `path` must carry.
        public var requiredHTTPHeaders: [String: String] = [:]

        public struct MediaStream: Codable, Equatable, Sendable {
            public var type: String?
            public var codec: String?
            public var level: Double?
            public var dvProfile: Int?
            public var index: Int?
            public var width: Int?
            public var height: Int?
            public var channels: Int?
            public var profile: String?
            public var videoRangeType: String?
            public var language: String?
            public var title: String?
            public var isExternal: Bool = false
            public var isForced: Bool = false
            /// "External", "Embed", "Encode", "Hls".
            public var deliveryMethod: String?
            public var deliveryURLPath: String?
            enum CodingKeys: String, CodingKey {
                case type = "Type", codec = "Codec", level = "Level", dvProfile = "DvProfile"
                case index = "Index", width = "Width", height = "Height"
                case channels = "Channels", profile = "Profile", videoRangeType = "VideoRangeType"
                case language = "Language", title = "Title"
                case isExternal = "IsExternal", isForced = "IsForced"
                case deliveryMethod = "DeliveryMethod", deliveryURLPath = "DeliveryUrl"
            }

            public init(type: String? = nil, codec: String? = nil, level: Double? = nil, dvProfile: Int? = nil, index: Int? = nil,
                        width: Int? = nil, height: Int? = nil, channels: Int? = nil, profile: String? = nil, videoRangeType: String? = nil) {
                self.type = type
                self.codec = codec
                self.level = level
                self.dvProfile = dvProfile
                self.index = index
                self.width = width
                self.height = height
                self.channels = channels
                self.profile = profile
                self.videoRangeType = videoRangeType
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                codec = try? container.decodeIfPresent(String.self, forKey: .codec)
                level = try? container.decodeIfPresent(Double.self, forKey: .level)
                dvProfile = container.lenientInt(forKey: .dvProfile)
                index = container.lenientInt(forKey: .index)
                width = container.lenientInt(forKey: .width)
                height = container.lenientInt(forKey: .height)
                channels = container.lenientInt(forKey: .channels)
                profile = try? container.decodeIfPresent(String.self, forKey: .profile)
                videoRangeType = try? container.decodeIfPresent(String.self, forKey: .videoRangeType)
                language = try? container.decodeIfPresent(String.self, forKey: .language)
                title = try? container.decodeIfPresent(String.self, forKey: .title)
                isExternal = (try? container.decodeIfPresent(Bool.self, forKey: .isExternal)) ?? false
                isForced = (try? container.decodeIfPresent(Bool.self, forKey: .isForced)) ?? false
                deliveryMethod = try? container.decodeIfPresent(String.self, forKey: .deliveryMethod)
                deliveryURLPath = try? container.decodeIfPresent(String.self, forKey: .deliveryURLPath)
            }

            /// Everything but `DeliveryUrl`, which can carry a token.
            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(type, forKey: .type)
                try container.encodeIfPresent(codec, forKey: .codec)
                try container.encodeIfPresent(level, forKey: .level)
                try container.encodeIfPresent(dvProfile, forKey: .dvProfile)
                try container.encodeIfPresent(index, forKey: .index)
                try container.encodeIfPresent(width, forKey: .width)
                try container.encodeIfPresent(height, forKey: .height)
                try container.encodeIfPresent(channels, forKey: .channels)
                try container.encodeIfPresent(profile, forKey: .profile)
                try container.encodeIfPresent(videoRangeType, forKey: .videoRangeType)
                try container.encodeIfPresent(language, forKey: .language)
                try container.encodeIfPresent(title, forKey: .title)
                try container.encode(isExternal, forKey: .isExternal)
                try container.encode(isForced, forKey: .isForced)
                try container.encodeIfPresent(deliveryMethod, forKey: .deliveryMethod)
            }

            public var isSubtitle: Bool { type?.lowercased() == "subtitle" }
        }

        /// A stand-in the server may resolve only when asked to stream it:
        /// tried after the real sources, always through the server.
        public var isPlaceholder: Bool { sourceType?.lowercased() == "placeholder" }

        /// `path` as a URL to play directly, when the server says the media
        /// lives on another http(s) host rather than in its own storage.
        public var remoteURL: URL? {
            guard !isPlaceholder, isRemote || protocolName?.lowercased() == "http",
                  let path, let url = URL(string: path),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
            return url
        }

        public var descriptors: AppleStreamDescriptors {
            let video = mediaStreams.first { $0.type?.lowercased() == "video" }
            let audio = mediaStreams.first { $0.type?.lowercased() == "audio" }
            let subtitle = mediaStreams.first { $0.type?.lowercased() == "subtitle" }
            let isHEVC = ["hevc", "h265", "hvc1", "hev1", "x265", "dvhe", "dvh1"].contains(video?.codec?.lowercased() ?? "")
            let level = video?.level.map { $0 > 10 ? $0 / (isHEVC ? 30 : 10) : $0 }
            return .init(container: container, videoCodec: video?.codec, videoLevel: level,
                dolbyVisionProfile: video?.dvProfile.flatMap { $0 > 0 ? $0 : nil }, audioCodec: audio?.codec, subtitleCodec: subtitle?.codec,
                bitrate: bitrate, duration: runtimeTicks.map { Double($0) / 10_000_000 }, width: video?.width, height: video?.height)
        }

        public var formatBadges: [AppleStreamFormatBadge] {
            let video = mediaStreams.first { $0.type?.lowercased() == "video" }
            let audio = mediaStreams.first { $0.type?.lowercased() == "audio" }
            let rawRange = video?.videoRangeType?.lowercased() ?? ""
            let range: AppleStreamFormatBadge.ProbedFormat.DynamicRange
            if (video?.dvProfile ?? 0) > 0 || rawRange.contains("dovi") { range = .dolbyVision }
            else if rawRange.contains("hdr10+") || rawRange.contains("hdr10plus") { range = .hdr10Plus }
            else if rawRange.contains("hlg") { range = .hlg }
            else if rawRange.contains("hdr") { range = .hdr10 }
            else { range = .sdr }
            let probed = AppleStreamFormatBadge.badges(for: .init(width: video?.width ?? 0, height: video?.height ?? 0,
                dynamicRange: range, audioChannels: audio?.channels ?? 0))
            return AppleStreamFormatBadge.merged(probed: probed, named: AppleStreamFormatBadge.parse(name ?? ""))
        }

        public var versionLabel: String {
            [name, container?.uppercased(), id].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? id
        }

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case supportsDirectPlay = "SupportsDirectPlay"
            case supportsDirectStream = "SupportsDirectStream"
            case transcodingURLPath = "TranscodingUrl"
            case directStreamURLPath = "DirectStreamUrl"
            case name = "Name"
            case size = "Size", runtimeTicks = "RunTimeTicks", bitrate = "Bitrate", mediaStreams = "MediaStreams"
            case path = "Path", protocolName = "Protocol", isRemote = "IsRemote"
            case requiredHTTPHeaders = "RequiredHttpHeaders"
            case sourceType = "Type"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            size = container.lenientInt64(forKey: .size)
            runtimeTicks = container.lenientInt64(forKey: .runtimeTicks)
            bitrate = container.lenientInt(forKey: .bitrate)
            mediaStreams = (try? container.decodeIfPresent(AppleLossyArray<MediaStream>.self, forKey: .mediaStreams))?.values ?? []
            self.container = try? container.decodeIfPresent(String.self, forKey: .container)
            supportsDirectPlay = (try? container.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay)) ?? false
            supportsDirectStream = (try? container.decodeIfPresent(Bool.self, forKey: .supportsDirectStream)) ?? false
            transcodingURLPath = try? container.decodeIfPresent(String.self, forKey: .transcodingURLPath)
            directStreamURLPath = try? container.decodeIfPresent(String.self, forKey: .directStreamURLPath)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            path = try? container.decodeIfPresent(String.self, forKey: .path)
            protocolName = try? container.decodeIfPresent(String.self, forKey: .protocolName)
            sourceType = try? container.decodeIfPresent(String.self, forKey: .sourceType)
            isRemote = (try? container.decodeIfPresent(Bool.self, forKey: .isRemote)) ?? false
            requiredHTTPHeaders = (try? container.decodeIfPresent([String: String].self, forKey: .requiredHTTPHeaders)) ?? [:]
        }
        
        public init(id: String, container: String? = nil, supportsDirectPlay: Bool = false, supportsDirectStream: Bool = false, transcodingURLPath: String? = nil, directStreamURLPath: String? = nil, name: String? = nil) {
            self.id = id
            self.container = container
            self.supportsDirectPlay = supportsDirectPlay
            self.supportsDirectStream = supportsDirectStream
            self.transcodingURLPath = transcodingURLPath
            self.directStreamURLPath = directStreamURLPath
            self.name = name
        }
        
        /// Leaves out every link and header: they can carry the server's or
        /// another host's credentials, which never go into a saved file.
        public func encode(to encoder: Encoder) throws {
            var enc = encoder.container(keyedBy: CodingKeys.self)
            try enc.encode(id, forKey: .id)
            try enc.encodeIfPresent(container, forKey: .container)
            try enc.encodeIfPresent(size, forKey: .size)
            try enc.encodeIfPresent(runtimeTicks, forKey: .runtimeTicks)
            try enc.encodeIfPresent(bitrate, forKey: .bitrate)
            try enc.encode(mediaStreams, forKey: .mediaStreams)
            try enc.encode(supportsDirectPlay, forKey: .supportsDirectPlay)
            try enc.encode(supportsDirectStream, forKey: .supportsDirectStream)
            try enc.encodeIfPresent(name, forKey: .name)
            try enc.encodeIfPresent(protocolName, forKey: .protocolName)
            try enc.encodeIfPresent(sourceType, forKey: .sourceType)
            try enc.encode(isRemote, forKey: .isRemote)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case playSessionID = "PlaySessionId"
        case mediaSources = "MediaSources"
        case errorCode = "ErrorCode"
        case defaultMediaSourceID = "DefaultMediaSourceId"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playSessionID = try? container.decodeIfPresent(String.self, forKey: .playSessionID)
        errorCode = try? container.decodeIfPresent(String.self, forKey: .errorCode)
        defaultMediaSourceID = try? container.decodeIfPresent(String.self, forKey: .defaultMediaSourceID)
        mediaSources = (try? container.decodeIfPresent(AppleLossyArray<MediaSource>.self, forKey: .mediaSources))?.values ?? []
    }
    
    public init(playSessionID: String?, mediaSources: [MediaSource], defaultMediaSourceID: String? = nil) {
        self.playSessionID = playSessionID
        self.mediaSources = mediaSources
        self.defaultMediaSourceID = defaultMediaSourceID
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(playSessionID, forKey: .playSessionID)
        try container.encode(mediaSources, forKey: .mediaSources)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(defaultMediaSourceID, forKey: .defaultMediaSourceID)
    }

    /// The server's own word that it has nothing this device can play.
    public var saysNoCompatibleStream: Bool {
        errorCode?.caseInsensitiveCompare("NoCompatibleStream") == .orderedSame
    }
}

public enum AppleMediaServerImageType: String, Codable, Equatable, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
}

public enum AppleMediaServerTicks {
    public static func seconds(fromTicks ticks: Int64) -> Double {
        return Double(ticks) / 10_000_000.0
    }
    
    public static func ticks(fromSeconds seconds: Double) -> Int64 {
        return Int64(seconds * 10_000_000.0)
    }
}

extension AppleMediaServerClient {
    public func collections(session: AppleMediaServerSession, parentID: String? = nil) async throws -> [AppleMediaServerLibrary] {
        var collections: [AppleMediaServerLibrary] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items", queryItems: [
                URLQueryItem(name: "ParentId", value: parentID), URLQueryItem(name: "IncludeItemTypes", value: "BoxSet"),
                URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "StartIndex", value: String(offset)),
                URLQueryItem(name: "Limit", value: "100")].filter { $0.value != nil })
            let data = try await perform(request(url: url, token: session.accessToken))
            let page = try JSONDecoder().decode(AppleMediaServerItemList<AppleMediaServerLibrary>.self, from: data)
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            collections += fresh
            offset += page.receivedCount
            if page.receivedCount < 100 || (!page.items.isEmpty && fresh.isEmpty) { return collections }
        }
    }

    public func libraries(session: AppleMediaServerSession) async throws -> [AppleMediaServerLibrary] {
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Views")
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        
        return try JSONDecoder().decode(AppleMediaServerItemList<AppleMediaServerLibrary>.self, from: data).items
    }
    
    public func items(
        session: AppleMediaServerSession,
        parentID: String?,
        includeTypes: [AppleMediaServerItemType] = [],
        recursive: Bool = true,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        startIndex: Int = 0,
        limit: Int = 100,
        genres: [String] = [],
        providerIDs: [String] = [],
        searchTerm: String? = nil,
        years: [Int] = []
    ) async throws -> AppleMediaServerItemPage {
        var query: [URLQueryItem] = []
        if let parentID = parentID {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        if !includeTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.map(\.rawValue).joined(separator: ",")))
        }
        if !genres.isEmpty { query.append(URLQueryItem(name: "Genres", value: genres.joined(separator: "|"))) }
        if !providerIDs.isEmpty { query.append(URLQueryItem(name: "AnyProviderIdEquals", value: providerIDs.joined(separator: ","))) }
        if let searchTerm { query.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }
        if !years.isEmpty { query.append(URLQueryItem(name: "Years", value: years.map(String.init).joined(separator: ","))) }
        query.append(URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"))
        query.append(URLQueryItem(name: "SortBy", value: sortBy))
        query.append(URLQueryItem(name: "SortOrder", value: sortOrder))
        query.append(URLQueryItem(name: "StartIndex", value: String(startIndex)))
        query.append(URLQueryItem(name: "Limit", value: String(limit)))
        query.append(URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId"))
        query.append(URLQueryItem(name: "ImageTypeLimit", value: "1"))
        query.append(URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"))
        
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        return try JSONDecoder().decode(AppleMediaServerItemPage.self, from: data)
    }

    public func latest(
        session: AppleMediaServerSession,
        parentID: String?,
        limit: Int = 20
    ) async throws -> [AppleMediaServerItem] {
        var query: [URLQueryItem] = []
        if let parentID = parentID {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        query.append(URLQueryItem(name: "Limit", value: String(limit)))
        query.append(URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId,DateCreated"))
        query.append(URLQueryItem(name: "ImageTypeLimit", value: "1"))
        query.append(URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"))
        
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items/Latest", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        return try JSONDecoder().decode(AppleLossyArray<AppleMediaServerItem>.self, from: data).values
    }

    public func nextUp(session: AppleMediaServerSession, parentID: String, startIndex: Int = 0, limit: Int = 20) async throws -> AppleMediaServerItemPage {
        let query = [URLQueryItem(name: "UserId", value: session.userID)]
            + (parentID.isEmpty ? [] : [URLQueryItem(name: "ParentId", value: parentID)]) + [
                     URLQueryItem(name: "StartIndex", value: String(max(0, startIndex))),
                     URLQueryItem(name: "Limit", value: String(min(100, max(1, limit)))),
                     URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId")]
        let url = try normalizedURL(base: session.baseURL, path: "Shows/NextUp", queryItems: query)
        let data = try await perform(request(url: url, token: session.accessToken))
        return try JSONDecoder().decode(AppleMediaServerItemPage.self, from: data)
    }

    public func resume(
        session: AppleMediaServerSession,
        limit: Int = 20
    ) async throws -> AppleMediaServerItemPage {
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "MediaTypes", value: "Video"))
        query.append(URLQueryItem(name: "Limit", value: String(limit)))
        query.append(URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId"))
        query.append(URLQueryItem(name: "ImageTypeLimit", value: "1"))
        query.append(URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"))
        
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items/Resume", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        return try JSONDecoder().decode(AppleMediaServerItemPage.self, from: data)
    }

    public func item(
        session: AppleMediaServerSession,
        id: String
    ) async throws -> AppleMediaServerItem {
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items/\(id)")
        let req = request(url: url, token: session.accessToken)
        let data = try await performAnswered(req)
        return try JSONDecoder().decode(AppleMediaServerItem.self, from: data)
    }
    
    public func seasons(
        session: AppleMediaServerSession,
        seriesID: String
    ) async throws -> [AppleMediaServerItem] {
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "UserId", value: session.userID))
        
        let url = try normalizedURL(base: session.baseURL, path: "Shows/\(seriesID)/Seasons", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await performAnswered(req)
        
        return try JSONDecoder().decode(AppleMediaServerItemList<AppleMediaServerItem>.self, from: data).items
    }
    
    public func episodes(
        session: AppleMediaServerSession,
        seriesID: String,
        seasonID: String?
    ) async throws -> [AppleMediaServerItem] {
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "UserId", value: session.userID))
        if let seasonID = seasonID {
            query.append(URLQueryItem(name: "SeasonId", value: seasonID))
        }
        query.append(URLQueryItem(name: "Fields", value: "Overview,RunTimeTicks,SeriesId,SeasonId"))
        
        let url = try normalizedURL(base: session.baseURL, path: "Shows/\(seriesID)/Episodes", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await performAnswered(req)
        
        return try JSONDecoder().decode(AppleMediaServerItemList<AppleMediaServerItem>.self, from: data).items
    }
    
    public func playbackInfo(
        session: AppleMediaServerSession,
        itemID: String,
        forceConversion: Bool = false,
        mediaSourceID: String? = nil
    ) async throws -> AppleMediaServerPlaybackInfo {
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "UserId", value: session.userID))
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        
        let url = try normalizedURL(base: session.baseURL, path: "Items/\(itemID)/PlaybackInfo", queryItems: query)
        var req = request(url: url, method: "POST", token: session.accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "UserId": session.userID,
            "DeviceProfile": AppleJellyfinPlaybackPolicy.deviceProfile,
            "EnableDirectPlay": !forceConversion,
            "EnableDirectStream": !forceConversion,
            "EnableTranscoding": true,
            "AutoOpenLiveStream": true
        ]
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let playbackRequest = req
        let key = [url.absoluteString, session.accessToken, String(forceConversion)]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return try await playbackInfoLookups.value(for: ApplePlaybackIdentity.digest(for: key)) { [self] in
            appleTrace("media server playback info request conversion=\(forceConversion) manual=\(mediaSourceID != nil)")
            let data = try await perform(playbackRequest)
            return try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: data)
        }
    }
    
    public func directStreamURL(
        session: AppleMediaServerSession,
        itemID: String,
        mediaSourceID: String,
        container: String?
    ) throws -> URL {
        var path = "Videos/\(itemID)/stream"
        if let container = container, !container.isEmpty {
            path += ".\(container)"
        }
        
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "static", value: "true"))
        query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceID))
        query.append(URLQueryItem(name: "api_key", value: session.accessToken))
        
        return try normalizedURL(base: session.baseURL, path: path, queryItems: query)
    }
    
    public func imageURL(
        session: AppleMediaServerSession,
        itemID: String,
        type: AppleMediaServerImageType,
        tag: String?,
        maxWidth: Int?
    ) throws -> URL {
        var query: [URLQueryItem] = []
        if let tag = tag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        if let maxWidth = maxWidth {
            query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        
        return try normalizedURL(base: session.baseURL, path: "Items/\(itemID)/Images/\(type.rawValue)", queryItems: query)
    }
    
    public func reportPlaybackStart(
        session: AppleMediaServerSession,
        itemID: String,
        mediaSourceID: String,
        playSessionID: String?,
        positionSeconds: Double
    ) async throws {
        let url = try normalizedURL(base: session.baseURL, path: "Sessions/Playing")
        var req = request(url: url, method: "POST", token: session.accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemID,
            "MediaSourceId": mediaSourceID,
            "PositionTicks": AppleMediaServerTicks.ticks(fromSeconds: positionSeconds),
            "CanSeek": true,
            "PlayMethod": "DirectStream"
        ]
        if let playSessionID = playSessionID {
            body["PlaySessionId"] = playSessionID
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await perform(req)
    }
    
    public func reportPlaybackProgress(
        session: AppleMediaServerSession,
        itemID: String,
        mediaSourceID: String,
        playSessionID: String?,
        positionSeconds: Double,
        isPaused: Bool
    ) async throws {
        let url = try normalizedURL(base: session.baseURL, path: "Sessions/Playing/Progress")
        var req = request(url: url, method: "POST", token: session.accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemID,
            "MediaSourceId": mediaSourceID,
            "PositionTicks": AppleMediaServerTicks.ticks(fromSeconds: positionSeconds),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": "DirectStream"
        ]
        if let playSessionID = playSessionID {
            body["PlaySessionId"] = playSessionID
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await perform(req)
    }
    
    public func reportPlaybackStopped(
        session: AppleMediaServerSession,
        itemID: String,
        mediaSourceID: String,
        playSessionID: String?,
        positionSeconds: Double
    ) async throws {
        let url = try normalizedURL(base: session.baseURL, path: "Sessions/Playing/Stopped")
        var req = request(url: url, method: "POST", token: session.accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemID,
            "MediaSourceId": mediaSourceID,
            "PositionTicks": AppleMediaServerTicks.ticks(fromSeconds: positionSeconds),
            "CanSeek": true,
            "PlayMethod": "DirectStream"
        ]
        if let playSessionID = playSessionID {
            body["PlaySessionId"] = playSessionID
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await perform(req)
    }
}
