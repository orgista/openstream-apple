import Foundation
import CryptoKit

public struct AppleIPTVProgramme: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let channelID: String
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let start: Date
    public let end: Date
    public let category: String?
    public let isLive: Bool

    public init(id: String, channelID: String, title: String, subtitle: String?, description: String?, start: Date, end: Date, category: String?, isLive: Bool) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.start = start
        self.end = end
        self.category = category
        self.isLive = isLive
    }
}

public struct AppleIPTVGuide: Sendable {
    public let channelNames: [String: String]
    let channelMatchIndex: AppleIPTVGuideMatching.Index
    private let programmesByChannel: [String: [AppleIPTVProgramme]]
    /// Prefix maxima let a lookup stop once no earlier programme can still
    /// be on air. This preserves overlapping XMLTV entries and schedule gaps.
    private let maximumEndsByChannel: [String: [Date]]

    public init(programmes: [AppleIPTVProgramme], channelNames: [String: String] = [:]) {
        self.channelNames = channelNames
        channelMatchIndex = AppleIPTVGuideMatching.Index(names: channelNames)
        var grouped = [String: [AppleIPTVProgramme]]()
        for p in programmes {
            grouped[p.channelID, default: []].append(p)
        }
        for (key, value) in grouped {
            grouped[key] = value.sorted { $0.start < $1.start }
        }
        self.programmesByChannel = grouped
        maximumEndsByChannel = grouped.mapValues { programmes in
            var maximum = programmes.first?.end ?? .distantPast
            return programmes.map { programme in
                maximum = max(maximum, programme.end)
                return maximum
            }
        }
    }

    var allProgrammes: [AppleIPTVProgramme] { programmesByChannel.values.flatMap { $0 } }

    public func nowAndNext(channelID: String, at time: Date = Date()) -> (now: AppleIPTVProgramme?, next: AppleIPTVProgramme?) {
        guard let programmes = programmesByChannel[channelID],
              let maximumEnds = maximumEndsByChannel[channelID] else { return (nil, nil) }

        // First start strictly after time: no scan of every earlier programme
        // when a focus move asks for the current show. The guide is immutable,
        // so the index is rebuilt only when programme data changes.
        var lower = 0
        var upper = programmes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if programmes[middle].start <= time { lower = middle + 1 }
            else { upper = middle }
        }
        let next = lower < programmes.count ? programmes[lower] : nil
        var index = lower
        while index > 0 {
            index -= 1
            guard maximumEnds[index] > time else { break }
            if programmes[index].end > time { return (programmes[index], next) }
        }
        return (nil, next)
    }

    public func programmes(channelID: String, in interval: DateInterval) -> [AppleIPTVProgramme] {
        guard let channelProgrammes = programmesByChannel[channelID] else { return [] }
        return channelProgrammes.filter { p in
            return p.start < interval.end && p.end > interval.start
        }
    }
}

public actor AppleIPTVGuideLoader {
    private let client: AppleBoundedHTTPClient
    /// A national XMLTV file is 10–40 MB uncompressed (open-epg France is
    /// 10.6 MB); 8 MB silently emptied the guide (owner, 2026-09-17).
    public static let maximumGuideBytes = 48 * 1024 * 1024
    /// Guide hosts redirect (`files/france.xml` → `app/download.php`); only
    /// https→https is followed.
    static let redirectPolicy: AppleHTTPRedirectPolicy = .secureHTTPOnly
    public static let requestTimeout: TimeInterval = 30
    private var maxBytes: Int { Self.maximumGuideBytes }

    public init(session: URLSession? = nil) {
        let configuration = session?.configuration ?? .ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout * 3
        client = AppleBoundedHTTPClient(configuration: configuration)
    }

    public struct XMLTVResponse: Sendable {
        public let guide: AppleIPTVGuide?
        public let eTag: String?
        public let lastModified: String?
        public let contentDigest: String?
    }

    public func load(xmltvURL: URL?, defaultOffsetHours: Double = 0) async throws -> AppleIPTVGuide {
        guard let xmltvURL else { return AppleIPTVGuide(programmes: []) }
        guard let guide = try await loadXMLTV(url: xmltvURL, defaultOffsetHours: defaultOffsetHours).guide else {
            throw URLError(.badServerResponse)
        }
        return guide
    }

    public func loadXMLTV(url: URL, defaultOffsetHours: Double = 0, eTag: String? = nil,
                          lastModified: String? = nil, contentDigest: String? = nil) async throws -> XMLTVResponse {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { throw AppleIPTVError.invalidEndpoint }
        return try await AppleImportStore.shared.run(title: "Programme Guide", unit: "programmes") { progress in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            let (data, response) = try await self.client.load(request, maximumBytes: Self.maximumGuideBytes,
                redirectPolicy: Self.redirectPolicy, behavior: .rejectOverflow) { bytes, total in
                    progress(.init(items: 0, bytes: bytes, totalBytes: total > 0 ? Int(total) : 0, phase: .downloading))
                }
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            let tag = response.value(forHTTPHeaderField: "ETag")
            let modified = response.value(forHTTPHeaderField: "Last-Modified")
            if response.statusCode == 304 {
                return XMLTVResponse(guide: nil, eTag: tag ?? eTag, lastModified: modified ?? lastModified, contentDigest: contentDigest)
            }
            guard 200..<300 ~= response.statusCode else { throw AppleIPTVError.requestFailed(response.statusCode) }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let guide = digest == contentDigest ? nil : try await Self.parseXMLTV(data, defaultOffsetHours: defaultOffsetHours, progress: progress)
            return XMLTVResponse(guide: guide, eTag: tag, lastModified: modified, contentDigest: digest)
        }
    }

    @concurrent
    private static func parseXMLTV(_ data: Data, defaultOffsetHours: Double,
        progress: @escaping @Sendable (AppleImportProgress) -> Void) async throws -> AppleIPTVGuide {
        try AppleIPTVGuideXMLTVParser().validatedGuide(data: data, defaultOffsetHours: defaultOffsetHours, progress: progress)
    }

    /// - Parameter archiveStreamIDs: channels with catch-up. Those are read
    ///   with `get_simple_data_table`, which carries the past days the guide
    ///   can scroll back into; `get_short_epg` only lists what is coming.
    public func load(xtreamBase: URL, username: String, password: String, streamIDs: [Int],
                     archiveStreamIDs: Set<Int> = []) async throws -> AppleIPTVGuide {
        let ids = Array(Set(streamIDs.filter { $0 > 0 })).sorted().prefix(AppleIPTVClient.maximumChannels)
        return try await withThrowingTaskGroup(of: [AppleIPTVProgramme].self) { group in
            var iterator = ids.makeIterator()
            func enqueue(_ id: Int) {
                group.addTask {
                    try await self.loadStream(base: xtreamBase, username: username, password: password, id: id,
                                              action: archiveStreamIDs.contains(id) ? "get_simple_data_table" : "get_short_epg")
                }
            }
            for _ in 0..<4 { if let id = iterator.next() { enqueue(id) } }
            var programmes: [AppleIPTVProgramme] = []
            while let result = try await group.next() {
                try Task.checkCancellation()
                programmes.append(contentsOf: result)
                if let id = iterator.next() { enqueue(id) }
            }
            return AppleIPTVGuide(programmes: programmes)
        }
    }

    private func loadStream(base: URL, username: String, password: String, id: Int,
                            action: String = "get_short_epg") async throws -> [AppleIPTVProgramme] {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppleIPTVError.invalidEndpoint
        }
        if !components.path.hasSuffix("player_api.php") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + (components.path.isEmpty ? "" : components.path + "/") + "player_api.php"
        }
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "stream_id", value: String(id))
        ]
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        let data = try await fetch(url)
        return AppleIPTVGuideXtreamParser().parseShortEPG(data: data, streamID: String(id))
    }

    private func fetch(_ url: URL, progress: @escaping @Sendable (Int, Int64) -> Void = { _, _ in }) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { throw AppleIPTVError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await client.load(request, maximumBytes: maxBytes,
            redirectPolicy: Self.redirectPolicy, behavior: .rejectOverflow, progress: progress)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= response.statusCode else { throw AppleIPTVError.requestFailed(response.statusCode) }
        try Task.checkCancellation()
        return data
    }
}
