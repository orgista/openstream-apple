import Foundation

public struct AppleMediaServerLibrary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let collectionType: Kind
    
    public enum Kind: String, Codable, Equatable, Sendable {
        case movies
        case tvshows
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

public enum AppleMediaServerItemType: String, Codable, Equatable, Sendable {
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
    public let userData: UserData?
    
    public struct UserData: Codable, Equatable, Sendable {
        public let positionSeconds: Double
        public let played: Bool
        public let isFavorite: Bool
        public let playCount: Int
        
        private enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case played = "Played"
            case isFavorite = "IsFavorite"
            case playCount = "PlayCount"
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let ticks = try container.decodeIfPresent(Int64.self, forKey: .playbackPositionTicks) ?? 0
            positionSeconds = AppleMediaServerTicks.seconds(fromTicks: ticks)
            played = try container.decodeIfPresent(Bool.self, forKey: .played) ?? false
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        }
        
        public init(positionSeconds: Double = 0, played: Bool = false, isFavorite: Bool = false, playCount: Int = 0) {
            self.positionSeconds = positionSeconds
            self.played = played
            self.isFavorite = isFavorite
            self.playCount = playCount
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(AppleMediaServerTicks.ticks(fromSeconds: positionSeconds), forKey: .playbackPositionTicks)
            try container.encode(played, forKey: .played)
            try container.encode(isFavorite, forKey: .isFavorite)
            try container.encode(playCount, forKey: .playCount)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case year = "ProductionYear"
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
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        
        if let typeStr = try container.decodeIfPresent(String.self, forKey: .type),
           let t = AppleMediaServerItemType(rawValue: typeStr) {
            type = t
        } else {
            type = .other
        }
        
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        
        if let ticks = try container.decodeIfPresent(Int64.self, forKey: .runTimeTicks) {
            runtimeSeconds = AppleMediaServerTicks.seconds(fromTicks: ticks)
        } else {
            runtimeSeconds = nil
        }
        
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
        seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
        seasonID = try container.decodeIfPresent(String.self, forKey: .seasonID)
        indexNumber = try container.decodeIfPresent(Int.self, forKey: .indexNumber)
        parentIndexNumber = try container.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        
        let imageTags = try container.decodeIfPresent([String: String].self, forKey: .imageTags) ?? [:]
        primaryImageTag = imageTags["Primary"]
        logoImageTag = imageTags["Logo"]
        
        backdropImageTags = try container.decodeIfPresent([String].self, forKey: .backdropImageTags) ?? []
        providerIDs = try container.decodeIfPresent([String: String].self, forKey: .providerIDs) ?? [:]
        communityRating = try container.decodeIfPresent(Double.self, forKey: .communityRating)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        userData = try container.decodeIfPresent(UserData.self, forKey: .userData)
    }
    
    public init(id: String, name: String, type: AppleMediaServerItemType, year: Int? = nil, overview: String? = nil, runtimeSeconds: Double? = nil, seriesID: String? = nil, seriesName: String? = nil, seasonID: String? = nil, indexNumber: Int? = nil, parentIndexNumber: Int? = nil, primaryImageTag: String? = nil, logoImageTag: String? = nil, backdropImageTags: [String] = [], providerIDs: [String: String] = [:], communityRating: Double? = nil, genres: [String] = [], userData: UserData? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.year = year
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
    }
}

extension AppleMediaServerItem {
    /// The same item with new viewer state (position, played, favourite, play count).
    public func withUserData(_ userData: UserData?) -> AppleMediaServerItem {
        AppleMediaServerItem(
            id: id, name: name, type: type, year: year, overview: overview, runtimeSeconds: runtimeSeconds,
            seriesID: seriesID, seriesName: seriesName, seasonID: seasonID, indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber, primaryImageTag: primaryImageTag, logoImageTag: logoImageTag,
            backdropImageTags: backdropImageTags, providerIDs: providerIDs, communityRating: communityRating,
            genres: genres, userData: userData)
    }
}

public struct AppleMediaServerItemPage: Codable, Equatable, Sendable {
    public let items: [AppleMediaServerItem]
    public let totalRecordCount: Int
    
    private enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([AppleMediaServerItem].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
    }
    
    public init(items: [AppleMediaServerItem], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
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
    
    public struct MediaSource: Codable, Equatable, Sendable {
        public let id: String
        public let container: String?
        public let supportsDirectPlay: Bool
        public let supportsDirectStream: Bool
        public let transcodingURLPath: String?
        public let directStreamURLPath: String?
        public let name: String?
        
        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case supportsDirectPlay = "SupportsDirectPlay"
            case supportsDirectStream = "SupportsDirectStream"
            case transcodingURLPath = "TranscodingUrl"
            case directStreamURLPath = "DirectStreamUrl"
            case name = "Name"
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            self.container = try container.decodeIfPresent(String.self, forKey: .container)
            supportsDirectPlay = try container.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay) ?? false
            supportsDirectStream = try container.decodeIfPresent(Bool.self, forKey: .supportsDirectStream) ?? false
            transcodingURLPath = try container.decodeIfPresent(String.self, forKey: .transcodingURLPath)
            directStreamURLPath = try container.decodeIfPresent(String.self, forKey: .directStreamURLPath)
            name = try container.decodeIfPresent(String.self, forKey: .name)
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
        
        public func encode(to encoder: Encoder) throws {
            var enc = encoder.container(keyedBy: CodingKeys.self)
            try enc.encode(id, forKey: .id)
            try enc.encodeIfPresent(container, forKey: .container)
            try enc.encode(supportsDirectPlay, forKey: .supportsDirectPlay)
            try enc.encode(supportsDirectStream, forKey: .supportsDirectStream)
            try enc.encodeIfPresent(transcodingURLPath, forKey: .transcodingURLPath)
            try enc.encodeIfPresent(directStreamURLPath, forKey: .directStreamURLPath)
            try enc.encodeIfPresent(name, forKey: .name)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case playSessionID = "PlaySessionId"
        case mediaSources = "MediaSources"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playSessionID = try container.decodeIfPresent(String.self, forKey: .playSessionID)
        mediaSources = try container.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
    }
    
    public init(playSessionID: String?, mediaSources: [MediaSource]) {
        self.playSessionID = playSessionID
        self.mediaSources = mediaSources
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(playSessionID, forKey: .playSessionID)
        try container.encode(mediaSources, forKey: .mediaSources)
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
    public func libraries(session: AppleMediaServerSession) async throws -> [AppleMediaServerLibrary] {
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Views")
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        
        struct Response: Codable {
            let items: [AppleMediaServerLibrary]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        
        return try JSONDecoder().decode(Response.self, from: data).items
    }
    
    public func items(
        session: AppleMediaServerSession,
        parentID: String?,
        includeTypes: [AppleMediaServerItemType] = [],
        recursive: Bool = true,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> AppleMediaServerItemPage {
        var query: [URLQueryItem] = []
        if let parentID = parentID {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        if !includeTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.map(\.rawValue).joined(separator: ",")))
        }
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
        query.append(URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId"))
        query.append(URLQueryItem(name: "ImageTypeLimit", value: "1"))
        query.append(URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"))
        
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items/Latest", queryItems: query)
        let req = request(url: url, token: session.accessToken)
        let data = try await perform(req)
        return try JSONDecoder().decode([AppleMediaServerItem].self, from: data)
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
        let data = try await perform(req)
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
        let data = try await perform(req)
        
        struct Response: Codable {
            let items: [AppleMediaServerItem]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        
        return try JSONDecoder().decode(Response.self, from: data).items
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
        let data = try await perform(req)
        
        struct Response: Codable {
            let items: [AppleMediaServerItem]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        
        return try JSONDecoder().decode(Response.self, from: data).items
    }
    
    public func playbackInfo(
        session: AppleMediaServerSession,
        itemID: String
    ) async throws -> AppleMediaServerPlaybackInfo {
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "UserId", value: session.userID))
        
        let url = try normalizedURL(base: session.baseURL, path: "Items/\(itemID)/PlaybackInfo", queryItems: query)
        var req = request(url: url, method: "POST", token: session.accessToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "UserId": session.userID,
            "MaxStreamingBitrate": 140000000,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "AutoOpenLiveStream": true
        ]
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let data = try await perform(req)
        return try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: data)
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
