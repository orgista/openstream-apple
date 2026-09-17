import Foundation

public struct AppleIPTVProgramme: Identifiable, Sendable, Equatable {
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
    private let programmesByChannel: [String: [AppleIPTVProgramme]]

    public init(programmes: [AppleIPTVProgramme]) {
        var grouped = [String: [AppleIPTVProgramme]]()
        for p in programmes {
            grouped[p.channelID, default: []].append(p)
        }
        for (key, value) in grouped {
            grouped[key] = value.sorted { $0.start < $1.start }
        }
        self.programmesByChannel = grouped
    }

    public func nowAndNext(channelID: String, at time: Date = Date()) -> (now: AppleIPTVProgramme?, next: AppleIPTVProgramme?) {
        guard let channelProgrammes = programmesByChannel[channelID] else { return (nil, nil) }
        
        var now: AppleIPTVProgramme? = nil
        var next: AppleIPTVProgramme? = nil
        
        for p in channelProgrammes {
            if p.start <= time && p.end > time {
                now = p
            } else if p.start > time {
                if next == nil || p.start < next!.start {
                    next = p
                    break
                }
            }
        }
        
        return (now, next)
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
    private let maxBytes = 8 * 1024 * 1024

    public init(session: URLSession? = nil) {
        let configuration = session?.configuration ?? .ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        client = AppleBoundedHTTPClient(configuration: configuration)
    }

    public func load(xmltvURL: URL?) async throws -> AppleIPTVGuide {
        guard let url = xmltvURL else { return AppleIPTVGuide(programmes: []) }
        let data = try await fetch(url)
        return AppleIPTVGuide(programmes: AppleIPTVGuideXMLTVParser().parse(data: data))
    }

    public func load(xtreamBase: URL, username: String, password: String, streamIDs: [Int]) async throws -> AppleIPTVGuide {
        let ids = Array(Set(streamIDs.filter { $0 > 0 })).sorted().prefix(50)
        return try await withThrowingTaskGroup(of: [AppleIPTVProgramme].self) { group in
            var iterator = ids.makeIterator()
            func enqueue(_ id: Int) {
                group.addTask {
                    try await self.loadStream(base: xtreamBase, username: username, password: password, id: id)
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

    private func loadStream(base: URL, username: String, password: String, id: Int) async throws -> [AppleIPTVProgramme] {
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
            URLQueryItem(name: "action", value: "get_short_epg"),
            URLQueryItem(name: "stream_id", value: String(id))
        ]
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        let data = try await fetch(url)
        return AppleIPTVGuideXtreamParser().parseShortEPG(data: data, streamID: String(id))
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { throw AppleIPTVError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await client.load(request, maximumBytes: maxBytes,
            redirectPolicy: .reject, behavior: .rejectOverflow)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= response.statusCode else { throw AppleIPTVError.requestFailed(response.statusCode) }
        try Task.checkCancellation()
        return data
    }
}
