import Foundation

public struct AppleIPTVChannel: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let sourceID: AppleSource.ID
    public let name: String
    public let group: String
    public let logoURL: URL?
    public let streamURL: URL
    public let userAgent: String?
    public let referer: String?
    public let origin: String?
    public let guideID: String?
    public let guideURL: URL?

    public init(
        id: String,
        sourceID: AppleSource.ID,
        name: String,
        group: String = "",
        logoURL: URL? = nil,
        streamURL: URL,
        userAgent: String? = nil,
        referer: String? = nil,
        origin: String? = nil,
        guideID: String? = nil,
        guideURL: URL? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.group = group
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.userAgent = userAgent
        self.referer = referer
        self.origin = origin
        self.guideID = guideID
        self.guideURL = guideURL
    }

    /// HTTP headers to attach to the media request, from the playlist's
    /// `#EXTVLCOPT` User-Agent/Referer/Origin. Empty when the playlist
    /// declared none.
    public var playbackHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        if let referer, !referer.isEmpty { headers["Referer"] = referer }
        if let origin, !origin.isEmpty { headers["Origin"] = origin }
        return headers
    }

    public func withGuideURL(_ guideURL: URL?) -> Self {
        Self(
            id: id,
            sourceID: sourceID,
            name: name,
            group: group,
            logoURL: logoURL,
            streamURL: streamURL,
            userAgent: userAgent,
            referer: referer,
            origin: origin,
            guideID: guideID,
            guideURL: guideURL
        )
    }
}

public enum AppleChannelVisibilityPolicy {
    public static func isPlaceholder(_ channel: AppleIPTVChannel) -> Bool {
        let value = channel.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return value.contains("no event")
    }

    /// East/unsuffixed is the canonical feed. Providers commonly export an
    /// identical West variant with the same number and normalized name.
    public static func isWestFeed(_ channel: AppleIPTVChannel) -> Bool {
        let value = channel.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return value.range(of: #"\s*\(?(west|w)\)?\s*$"#, options: .regularExpression) != nil
    }

    public static func deduplicatedEastChannels(_ channels: [AppleIPTVChannel]) -> [AppleIPTVChannel] {
        var seenNumbers = Set<Int>()
        var seenNames = Set<String>()
        return channels.filter { channel in
            guard !isWestFeed(channel), !isPlaceholder(channel) else { return false }
            let number = Int(channel.name.split(separator: " ").first ?? "")
            let normalized = channel.name
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .replacingOccurrences(of: #"\s*\(?(east|west|e|w)\)?\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let number, !seenNumbers.insert(number).inserted { return false }
            if !seenNames.insert(normalized).inserted { return false }
            return true
        }
    }

    public static func is24x7(_ channel: AppleIPTVChannel) -> Bool {
        func startsWithFillerPrefix(_ value: String) -> Bool {
            let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasPrefix("24/7") || normalized.hasPrefix("24-7") || normalized.hasPrefix("247")
        }
        return startsWithFillerPrefix(channel.group) || startsWithFillerPrefix(channel.name)
    }
    public static func isPayPerView(_ channel: AppleIPTVChannel) -> Bool {
        let value = "\(channel.name) \(channel.group)".lowercased()
        return ["pay-per-view", "pay per view", "ppv", "event only"]
            .contains(where: value.contains)
    }

    private static let regionalIndicators: Set<String> = [
        "region",
        "regions",
        "regional",
        "affiliate",
        "metro",
        "community",
        "area"
    ]

    private static let regionalPhrases: [String] = [
        "your regional",
        "region",
        "regional channel",
        "region channel",
        "regional channels",
        "local channels",
        "local channel",
        "affiliate channels",
        "affiliate channel",
        "metro channel",
        "metro channels"
    ]

    public static func isRegional(_ channel: AppleIPTVChannel, zipCode: String? = nil) -> Bool {
        if let zipCode {
            guard let normalizedZIP = AppleZIPCodePolicy.normalize(zipCode) else { return false }
            let text = normalizedRegionalText("\(channel.name) \(channel.group)")
            return text.contains(normalizedZIP) || text.contains("local") ||
                (try? AppleChannelLineupPresets.premierUS()).map {
                    AppleChannelLineupPresets.matchesLocalChannel(
                        name: channel.name,
                        zip: normalizedZIP,
                        entries: $0
                    )
                } ?? false
        }
        let normalized = normalizedRegionalText("\(channel.name) \(channel.group)")
        guard !normalized.isEmpty else { return false }

        let words = Set(normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        if !regionalIndicators.isDisjoint(with: words) {
            return true
        }

        for phrase in regionalPhrases {
            if normalized == phrase
                || normalized.hasPrefix("\(phrase) ")
                || normalized.hasSuffix(" \(phrase)")
                || normalized.contains(" \(phrase) ") {
                return true
            }
        }
        return false
    }

    private static func normalizedRegionalText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func visibleChannels(
        from channels: [AppleIPTVChannel],
        scope: AppleLiveChannelScope,
        showPayPerView: Bool,
        favoriteIDs: Set<String>,
        regionalZIPCode: String? = nil,
        show24x7: Bool = false
    ) -> [AppleIPTVChannel] {
        channels.filter { channel in
            let scopeMatches: Bool = switch scope {
            case .providerLineup:
                true
            case .regional:
                isRegional(channel, zipCode: regionalZIPCode)
            case .favorites:
                favoriteIDs.contains(channel.id)
            }
            return (show24x7 || !is24x7(channel)) && (showPayPerView || !isPayPerView(channel)) && scopeMatches
        }
    }
}

public struct AppleIPTVChannelGroup: Identifiable, Equatable, Sendable {
    public let name: String
    public let channels: [AppleIPTVChannel]
    public var id: String { name }

    public init(name: String, channels: [AppleIPTVChannel]) {
        self.name = name
        self.channels = channels
    }
}

/// Precomputes the potentially large Live/Channel Manager presentation away
/// from SwiftUI's render pass. Xtream playlists commonly contain thousands of
/// entries, so filtering and locale-aware sorting on every keystroke otherwise
/// blocks the main actor.
public enum AppleChannelProjection {
    public static func matchingChannels(
        from channels: [AppleIPTVChannel],
        query: String,
        show24x7: Bool = false
    ) -> [AppleIPTVChannel] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = clean.isEmpty ? channels : channels.filter {
            $0.name.localizedCaseInsensitiveContains(clean)
                || $0.group.localizedCaseInsensitiveContains(clean)
        }
        return matches.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func groupedChannels(
        from channels: [AppleIPTVChannel],
        scope: AppleLiveChannelScope,
        showPayPerView: Bool,
        favoriteIDs: Set<String>,
        query: String,
        regionalZIPCode: String? = nil,
        show24x7: Bool = false
    ) -> [AppleIPTVChannelGroup] {
        let visible = AppleChannelVisibilityPolicy.visibleChannels(
            from: channels,
            scope: scope,
            showPayPerView: showPayPerView,
            favoriteIDs: favoriteIDs,
            regionalZIPCode: regionalZIPCode,
            show24x7: show24x7
        )
        let matches = matchingChannels(from: visible, query: query)
        return Dictionary(grouping: matches) { channel in
            channel.group.isEmpty ? "Channels" : channel.group
        }
        .map { name, values in
            AppleIPTVChannelGroup(name: name, channels: values)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func premierGuideGroups(from channels: [AppleIPTVChannel], entries: [AppleChannelLineupEntry]) -> [AppleIPTVChannelGroup] {
        let index = AppleChannelLineupIndex(entries)
        let east = AppleChannelVisibilityPolicy.deduplicatedEastChannels(channels)
        var seenLineupNumbers = Set<Int>()
        let numbered = east.compactMap { channel -> (AppleChannelLineupEntry, AppleIPTVChannel)? in
            guard let entry = index.match(channel.name) else { return nil }
            guard seenLineupNumbers.insert(entry.number).inserted else { return nil }
            return (entry, channel)
        }.sorted { $0.0.number == $1.0.number ? $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending : $0.0.number < $1.0.number }
        let other = east.filter { index.match($0.name) == nil }
        return [
            numbered.isEmpty ? nil : AppleIPTVChannelGroup(name: "Premier Guide", channels: numbered.map { $0.1 }),
            other.isEmpty ? nil : AppleIPTVChannelGroup(name: "Other", channels: other),
        ].compactMap { $0 }
    }

    public static func buildMatchesOffMain(
        from channels: [AppleIPTVChannel],
        query: String,
        regionalZIPCode: String? = nil,
        show24x7: Bool = false
    ) async -> [AppleIPTVChannel] {
        await Task.detached(priority: .userInitiated) {
            matchingChannels(from: channels, query: query)
        }.value
    }

    public static func buildGroupsOffMain(
        from channels: [AppleIPTVChannel],
        scope: AppleLiveChannelScope,
        showPayPerView: Bool,
        favoriteIDs: Set<String>,
        query: String,
        regionalZIPCode: String? = nil,
        show24x7: Bool = false
    ) async -> [AppleIPTVChannelGroup] {
        await Task.detached(priority: .userInitiated) {
            groupedChannels(
                from: channels,
                scope: scope,
                showPayPerView: showPayPerView,
                favoriteIDs: favoriteIDs,
                query: query,
                regionalZIPCode: regionalZIPCode,
                show24x7: show24x7
            )
        }.value
    }
}

public enum AppleIPTVError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidSource
    case missingCredentials
    case authenticationFailed(status: String?)
    case unreachable(String)
    case httpStatus(Int)
    case unexpectedResponse(contentType: String?)
    case nonHTTPResponse
    case requestFailed(Int)
    case responseTooLarge
    case invalidPlaylist
    case noChannels
    case streamUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTP or HTTPS IPTV address."
        case .invalidSource: "This Live TV source is invalid."
        case .missingCredentials: "Username and password are required."
        case .authenticationFailed(let status):
            if let status, !status.isEmpty {
                "The IPTV provider rejected the account (auth=0, status: \(status)). Check the username and password, including capitalization."
            } else {
                "The IPTV provider rejected the account (auth=0). Check the username and password, including capitalization."
            }
        case .unreachable(let reason):
            "Could not reach the IPTV panel: \(reason). Check the network and that the address includes the port."
        case .httpStatus(let code):
            "The IPTV panel answered HTTP \(code) instead of account data."
        case .unexpectedResponse(let contentType):
            "The IPTV panel returned an unexpected page (\(contentType ?? "no content type")) instead of account data. A DNS filter, captive portal, or wrong address can cause this."
        case .nonHTTPResponse: "The IPTV server returned an invalid response."
        case .requestFailed(let status): "The IPTV request failed with HTTP \(status)."
        case .responseTooLarge: "The IPTV playlist is too large."
        case .invalidPlaylist: "The server did not return an M3U playlist."
        case .noChannels: "No playable channels were found."
        case .streamUnavailable: "The provider returned channels, but no tested channel delivered media data."
        }
    }
}

public enum AppleIPTVEndpointPolicy {
    public static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted/uploaded playlists live in the app (`openstream-playlist://local/…`).
        if let local = AppleLocalPlaylistStore.localURL(from: trimmed) { return local }
        let normalized = trimmed.contains("://")
            ? trimmed
            : "http://\(trimmed)"
        guard !trimmed.isEmpty,
              normalized.utf8.count <= 8_192,
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw AppleIPTVError.invalidEndpoint
        }
        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        return url
    }

    public static func isPlayable(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    public static func isProtectedPlaybackBridge(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return ["127.0.0.1", "::1", "localhost"].contains(host)
            && url.path.hasPrefix("/live/")
    }
}

public struct AppleIPTVClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias ProtectedPlaybackURL = @Sendable (URL, [String: String]) async throws -> URL

    public static let maximumResponseBytes = 12_000_000
    /// 25,000, up from 10,000. The owner's own provider is 9,376 channels, and
    /// the old cap sat 624 above it: one provider refresh, or two playlists
    /// merged into one ("it should be able to accept a larger amount at once",
    /// 2026-09-17), and the tail was dropped **silently** by the `break` below.
    /// The byte ceiling stays the real backstop — at ~245 bytes per entry in
    /// the owner's French playlist, 12 MB is ~49,000 entries — so this number
    /// only needs to sit comfortably above any real provider while staying
    /// under what the bytes could ever deliver.
    public static let maximumChannels = 25_000

    private let loader: Loader
    private let protectedPlaybackURL: ProtectedPlaybackURL

    public init(
        loader: @escaping Loader,
        protectedPlaybackURL: @escaping ProtectedPlaybackURL = AppleIPTVClient.liveProtectedPlaybackURL
    ) {
        self.loader = loader
        self.protectedPlaybackURL = protectedPlaybackURL
    }

    public init(
        protectedPlaybackURL: @escaping ProtectedPlaybackURL = AppleIPTVClient.liveProtectedPlaybackURL
    ) {
        self.loader = { request in try await AppleIPTVClient.liveLoader(request) }
        self.protectedPlaybackURL = protectedPlaybackURL
    }

    public func channels(
        source: AppleSource,
        credentials: AppleIPTVCredentials? = nil
    ) async throws -> [AppleIPTVChannel] {
        guard source.kind == .liveTV, source.isEnabled, let type = source.iptvType else {
            throw AppleIPTVError.invalidSource
        }
        let endpoint: URL
        switch type {
        case .m3u:
            endpoint = try AppleIPTVEndpointPolicy.normalize(source.url.absoluteString)
            if AppleLocalPlaylistStore.isLocal(endpoint) {
                let data = try AppleLocalPlaylistStore.shared.read(endpoint)
                let values = try Self.parseM3U(data, sourceID: source.id, baseURL: endpoint)
                guard !values.isEmpty else { throw AppleIPTVError.noChannels }
                return source.epgURL.map { epgURL in
                    values.map { channel in channel.withGuideURL(channel.guideURL ?? epgURL) }
                } ?? values
            }
        case .xtream:
            guard let credentials,
                  !credentials.username.isEmpty,
                  !credentials.password.isEmpty else {
                throw AppleIPTVError.missingCredentials
            }
            return try await xtreamChannels(source: source, credentials: credentials)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(
            "application/vnd.apple.mpegurl, application/x-mpegURL, audio/mpegurl, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes,
              response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw AppleIPTVError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else { throw AppleIPTVError.nonHTTPResponse }
        guard (200 ... 299).contains(http.statusCode) else { throw AppleIPTVError.requestFailed(http.statusCode) }
        let finalURL = http.url ?? endpoint
        guard AppleIPTVEndpointPolicy.isPlayable(finalURL) else { throw AppleIPTVError.invalidEndpoint }
        let values = try Self.parseM3U(data, sourceID: source.id, baseURL: finalURL)
        guard !values.isEmpty else { throw AppleIPTVError.noChannels }
        return source.epgURL.map { epgURL in
            values.map { channel in channel.withGuideURL(channel.guideURL ?? epgURL) }
        } ?? values
    }

    /// Validates the exact source and credentials that the Live TV form saves.
    /// Keeping this entry point separate from the channel-loading implementation
    /// lets connection tests and saves share one authoritative request path.
    public func validate(
        source: AppleSource,
        credentials: AppleIPTVCredentials? = nil
    ) async throws -> [AppleIPTVChannel] {
        try await channels(source: source, credentials: credentials)
    }

    /// Mints a short-lived loopback capability only when the user presses Play.
    /// This keeps provider credentials and required request headers out of
    /// AVFoundation while avoiding thousands of idle bridge sessions.
    public func playbackURL(for channel: AppleIPTVChannel) async throws -> URL {
        guard !AppleIPTVEndpointPolicy.isProtectedPlaybackBridge(channel.streamURL) else {
            return channel.streamURL
        }
        guard !channel.playbackHeaders.isEmpty else { return channel.streamURL }
        return try await protectedPlaybackURL(channel.streamURL, channel.playbackHeaders)
    }

    private func xtreamChannels(
        source: AppleSource,
        credentials: AppleIPTVCredentials
    ) async throws -> [AppleIPTVChannel] {
        let preferredExtension = try await verifyXtreamAccount(source: source, credentials: credentials)

        let categoryURL = try Self.xtreamAPIURL(
            baseURL: source.url,
            credentials: credentials,
            action: "get_live_categories"
        )
        let categories: [String: String]
        do {
            let data = try await load(categoryURL, accept: "application/json")
            let decoded = try JSONDecoder().decode(XtreamLossyArray<XtreamCategory>.self, from: data).values
            categories = Dictionary(uniqueKeysWithValues: decoded.compactMap { value in
                guard let id = value.categoryID?.value, !id.isEmpty else { return nil }
                return (id, String((value.categoryName ?? "").prefix(120)))
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            categories = [:]
        }

        let streamsURL = try Self.xtreamAPIURL(
            baseURL: source.url,
            credentials: credentials,
            action: "get_live_streams"
        )
        let streamData = try await load(streamsURL, accept: "application/json")
        let streams = try JSONDecoder().decode(XtreamLossyArray<XtreamLiveStream>.self, from: streamData).values

        var seen = Set<String>()
        var channels: [AppleIPTVChannel] = []
        for stream in streams {
            guard let streamID = stream.streamID?.value, !streamID.isEmpty,
                  let upstreamURL = try Self.xtreamStreamURL(
                      baseURL: source.url,
                      credentials: credentials,
                      stream: stream,
                      preferredExtension: preferredExtension
                  ),
                  seen.insert(streamID).inserted else { continue }
            let cleanName = (stream.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            channels.append(AppleIPTVChannel(
                id: "\(source.id.uuidString):\(streamID)",
                sourceID: source.id,
                name: String((cleanName.isEmpty ? "Channel \(channels.count + 1)" : cleanName).prefix(160)),
                group: String((stream.categoryID.flatMap { categories[$0.value] } ?? "").prefix(120)),
                logoURL: Self.safeArtworkURL(stream.streamIcon),
                streamURL: upstreamURL,
                userAgent: "OpenStream/1.0 Apple"
            ))
            if channels.count == Self.maximumChannels { break }
        }
        guard !channels.isEmpty else { throw AppleIPTVError.noChannels }
        return channels
    }

    /// Performs the Xtream `player_api.php` login probe and classifies the
    /// outcome precisely. This request is the actual account login, so its
    /// response is authoritative: every failure shape (unreachable panel,
    /// bad HTTP status, a block page instead of JSON, or a genuine auth
    /// rejection) surfaces its own actionable message instead of a single
    /// generic "rejected" error.
    private func verifyXtreamAccount(
        source: AppleSource,
        credentials: AppleIPTVCredentials
    ) async throws -> String? {
        let accountURL = try Self.xtreamAPIURL(baseURL: source.url, credentials: credentials, action: nil)
        var request = URLRequest(url: accountURL)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            throw AppleIPTVError.unreachable(urlError.localizedDescription)
        }

        guard data.count <= Self.maximumResponseBytes,
              response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw AppleIPTVError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppleIPTVError.unexpectedResponse(contentType: nil)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleIPTVError.httpStatus(http.statusCode)
        }
        guard let account = try? JSONDecoder().decode(XtreamAccountEnvelope.self, from: data),
              let userInfo = account.userInfo else {
            throw AppleIPTVError.unexpectedResponse(contentType: contentType)
        }
        guard userInfo.auth?.value == "1" else {
            throw AppleIPTVError.authenticationFailed(status: userInfo.status?.value)
        }
        return AppleXtreamOutputFormat.preferred(
            allowedOutputFormats: userInfo.allowedOutputFormats ?? []
        ).rawValue
    }

    private func load(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes,
              response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw AppleIPTVError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else { throw AppleIPTVError.nonHTTPResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppleIPTVError.authenticationFailed(status: nil)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleIPTVError.requestFailed(http.statusCode)
        }
        return data
    }

    public static func parseM3U(
        _ data: Data,
        sourceID: AppleSource.ID,
        baseURL: URL
    ) throws -> [AppleIPTVChannel] {
        guard data.count <= maximumResponseBytes,
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw data.count > maximumResponseBytes ? AppleIPTVError.responseTooLarge : AppleIPTVError.invalidPlaylist
        }
        let normalizedText = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let lines = normalizedText.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().hasPrefix("#EXTM3U") }) else {
            throw AppleIPTVError.invalidPlaylist
        }

        var pending: PendingChannel?
        let header = lines.first { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXTM3U") } ?? ""
        let attributes = parseAttributes(header)
        let guideLocation = (attributes["x-tvg-url"] ?? attributes["url-tvg"])?.split(separator: ",").first.map(String.init)
        let guideURL = guideLocation.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            .flatMap { AppleIPTVEndpointPolicy.isPlayable($0) ? $0 : nil }
        var userAgent: String?
        var referer: String?
        var origin: String?
        // Providers may expose many logical channels over one stream URL.
        // Deduplicate only exact repeated entries, never the URL alone.
        var seenEntries = Set<String>()
        var channels: [AppleIPTVChannel] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                pending = PendingChannel(extinf: line)
                userAgent = nil
                referer = nil
                origin = nil
                continue
            }
            if line.lowercased().hasPrefix("#extvlcopt:http-user-agent=") {
                userAgent = cleanHeader(String(line.dropFirst("#extvlcopt:http-user-agent=".count)))
                continue
            }
            if line.lowercased().hasPrefix("#extvlcopt:http-referrer=") ||
                line.lowercased().hasPrefix("#extvlcopt:http-referer=") {
                let separator = line.firstIndex(of: "=")
                referer = separator.flatMap { cleanHeader(String(line[line.index(after: $0)...])) }
                continue
            }
            if line.lowercased().hasPrefix("#extvlcopt:http-origin=") {
                let separator = line.firstIndex(of: "=")
                origin = separator.flatMap { cleanHeader(String(line[line.index(after: $0)...])) }
                continue
            }
            if line.lowercased().hasPrefix("#exthttp:"),
               let data = String(line.dropFirst("#EXTHTTP:".count)).data(using: .utf8),
               let values = try? JSONDecoder().decode([String: String].self, from: data) {
                userAgent = values.first {
                    $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
                }.flatMap { cleanHeader($0.value) } ?? userAgent
                referer = values.first {
                    $0.key.caseInsensitiveCompare("Referer") == .orderedSame ||
                        $0.key.caseInsensitiveCompare("Referrer") == .orderedSame
                }.flatMap { cleanHeader($0.value) } ?? referer
                origin = values.first {
                    $0.key.caseInsensitiveCompare("Origin") == .orderedSame
                }.flatMap { cleanHeader($0.value) } ?? origin
                continue
            }
            guard !line.hasPrefix("#"), let details = pending else { continue }
            pending = nil
            let cleanName = details.name.isEmpty ? "Channel \(channels.count + 1)" : details.name
            let providerID = details.attributes["tvg-id"]?.nonEmptyIPTVString ?? ""
            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                  AppleIPTVEndpointPolicy.isPlayable(url) else { continue }
            let entryKey = providerID.isEmpty
                ? url.absoluteString
                : "\(providerID)|\(cleanName)|\(url.absoluteString)"
            guard seenEntries.insert(entryKey).inserted else { continue }
            let stableID = ApplePlaybackIdentity.digest(for: "\(providerID)|\(url.absoluteString)")
            channels.append(AppleIPTVChannel(
                id: "\(sourceID.uuidString):\(stableID)",
                sourceID: sourceID,
                name: String(cleanName.prefix(160)),
                group: String((details.attributes["group-title"] ?? "").prefix(120)),
                logoURL: safeArtworkURL(details.attributes["tvg-logo"]),
                streamURL: url,
                userAgent: userAgent,
                referer: referer,
                origin: origin,
                guideID: providerID.isEmpty ? nil : providerID,
                guideURL: guideURL
            ))
            if channels.count == maximumChannels {
                // Never silently. The viewer sees a guide missing its tail and
                // has no way to know the playlist was cut, so say so where the
                // diagnostics log will carry it.
                let entries = lines.reduce(0) { $0 + ($1.uppercased().hasPrefix("#EXTINF:") ? 1 : 0) }
                appleTrace("iptv playlist truncated: kept \(channels.count) of \(entries) entries (maximumChannels)")
                break
            }
        }
        return channels
    }

    public static func xtreamPlaylistURL(
        baseURL: URL,
        username: String,
        password: String,
        allowedOutputFormats: [String] = ["m3u8"]
    ) throws -> URL {
        let normalized = try AppleIPTVEndpointPolicy.normalize(baseURL.absoluteString)
        guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
            throw AppleIPTVError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/get.php" : "/\(basePath)/get.php"
        let output = AppleXtreamOutputFormat.preferred(allowedOutputFormats: allowedOutputFormats).rawValue
        components.queryItems = [
            URLQueryItem(name: "username", value: username.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "password", value: password.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "type", value: "m3u_plus"),
            URLQueryItem(name: "output", value: output),
        ]
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        return url
    }

    public static func xtreamAPIURL(
        baseURL: URL,
        credentials: AppleIPTVCredentials,
        action: String?
    ) throws -> URL {
        let normalized = try AppleIPTVEndpointPolicy.normalize(baseURL.absoluteString)
        guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
            throw AppleIPTVError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/player_api.php" : "/\(basePath)/player_api.php"
        var query = [
            URLQueryItem(name: "username", value: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "password", value: credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if let action { query.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = query
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        return url
    }

    private static func xtreamStreamURL(
        baseURL: URL,
        credentials: AppleIPTVCredentials,
        stream: XtreamLiveStream,
        preferredExtension: String? = nil
    ) throws -> URL? {
        if let direct = safeArtworkURL(stream.directSource) { return direct }
        guard let streamID = stream.streamID?.value, !streamID.isEmpty,
              var components = URLComponents(
                  url: try AppleIPTVEndpointPolicy.normalize(baseURL.absoluteString),
                  resolvingAgainstBaseURL: false
              ) else { return nil }
        let ext = (preferredExtension ?? stream.containerExtension ?? "m3u8")
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let safeExtension = ext.isEmpty ? "m3u8" : String(ext.prefix(8))
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = basePath.isEmpty ? "" : "/\(basePath)"
        components.percentEncodedPath = "\(prefix)/live/\(encodedPathSegment(credentials.username))/\(encodedPathSegment(credentials.password))/\(encodedPathSegment(streamID)).\(safeExtension)"
        components.query = nil
        guard let url = components.url, AppleIPTVEndpointPolicy.isPlayable(url) else { return nil }
        return url
    }

    private static func encodedPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: maximumResponseBytes
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleIPTVError.responseTooLarge
        }
    }

    public static func liveProtectedPlaybackURL(_ upstreamURL: URL, headers: [String: String]) async throws -> URL {
        try await AppleProtectedHTTPPlaybackServer.shared.playbackURL(
            upstreamURL: upstreamURL,
            requestHeaders: headers
        )
    }

    private struct PendingChannel {
        let name: String
        let attributes: [String: String]

        init(extinf: String) {
            let metadataEnd = extinf.lastIndex(of: "\"")
                .map { extinf.index(after: $0) }
                ?? extinf.startIndex
            let comma = extinf[metadataEnd...].firstIndex(of: ",")
            name = comma.map { String(extinf[extinf.index(after: $0)...])
                .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let metadata = comma.map { String(extinf[..<$0]) } ?? extinf
            attributes = parseAttributes(metadata)
        }
    }

    private static func parseAttributes(_ value: String) -> [String: String] {
        guard let attributeExpression else { return [:] }
        let range = NSRange(value.startIndex..., in: value)
        return attributeExpression.matches(in: value, range: range).reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: value),
                  let valueRange = Range(match.range(at: 2), in: value) else { return }
            result[String(value[keyRange]).lowercased()] = String(value[valueRange])
        }
    }

    private static let attributeExpression = try? NSRegularExpression(
        pattern: #"([A-Za-z0-9_-]+)\s*=\s*\"([^\"]*)\""#
    )

    private static func safeArtworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func cleanHeader(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.utf8.count <= 512,
              !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return clean
    }
}

public struct AppleIPTVStreamProbeResult: Equatable, Sendable {
    public enum MediaKind: Equatable, Sendable {
        case hlsPlaylist
        case rawMPEGTransportStream
        case other
    }

    public let statusCode: Int
    public let bytesReceived: Int
    public let mediaKind: MediaKind

    public init(statusCode: Int, bytesReceived: Int, mediaKind: MediaKind = .other) {
        self.statusCode = statusCode
        self.bytesReceived = bytesReceived
        self.mediaKind = mediaKind
    }
}

public struct AppleIPTVStreamProbe: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let maximumProbeBytes = 32 * 1_024
    private let loader: Loader

    public init(loader: @escaping Loader = AppleIPTVStreamProbe.liveLoader) {
        self.loader = loader
    }

    public func validate(
        channels: [AppleIPTVChannel],
        maximumAttempts: Int = 3
    ) async throws -> AppleIPTVStreamProbeResult {
        guard !channels.isEmpty else { throw AppleIPTVError.noChannels }
        var lastError: (any Error)?
        for channel in channels.prefix(min(max(maximumAttempts, 1), 5)) {
            do {
                return try await validate(channel: channel)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw AppleIPTVError.streamUnavailable
    }

    public func validate(channel: AppleIPTVChannel) async throws -> AppleIPTVStreamProbeResult {
        guard AppleIPTVEndpointPolicy.isPlayable(channel.streamURL) else {
            throw AppleIPTVError.invalidEndpoint
        }
        var request = URLRequest(url: channel.streamURL)
        request.timeoutInterval = 15
        request.setValue("bytes=0-\(Self.maximumProbeBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("video/mp2t, application/vnd.apple.mpegurl, application/octet-stream, */*", forHTTPHeaderField: "Accept")
        request.setValue(channel.userAgent ?? "OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        if let referer = channel.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }

        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse else { throw AppleIPTVError.nonHTTPResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppleIPTVError.authenticationFailed(status: nil)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw AppleIPTVError.requestFailed(http.statusCode)
        }
        guard !data.isEmpty else { throw AppleIPTVError.streamUnavailable }
        return AppleIPTVStreamProbeResult(
            statusCode: http.statusCode,
            bytesReceived: min(data.count, Self.maximumProbeBytes),
            mediaKind: Self.mediaKind(data: data, response: http, url: channel.streamURL)
        )
    }

    private static func mediaKind(
        data: Data,
        response: HTTPURLResponse,
        url: URL
    ) -> AppleIPTVStreamProbeResult.MediaKind {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("mpegurl")
            || url.pathExtension.lowercased() == "m3u8"
            || data.prefix(7) == Data("#EXTM3U".utf8) {
            return .hlsPlaylist
        }
        let bytes = [UInt8](data.prefix(188 * 3))
        if bytes.first == 0x47,
           (bytes.count < 189 || bytes[188] == 0x47),
           (bytes.count < 377 || bytes[376] == 0x47) {
            return .rawMPEGTransportStream
        }
        return .other
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await AppleBoundedHTTPDataLoader.loadPrefix(
            request,
            maximumBytes: maximumProbeBytes
        )
    }
}

private struct XtreamFlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = String(value)
        } else if let value = try? container.decode(Bool.self) {
            self.value = value ? "1" : "0"
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string-like value.")
            )
        }
    }
}

private struct XtreamAccountEnvelope: Decodable {
    let userInfo: XtreamUserInfo?
    private enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
}

private struct XtreamUserInfo: Decodable {
    let auth: XtreamFlexibleString?
    let status: XtreamFlexibleString?
    let allowedOutputFormats: [String]?

    private enum CodingKeys: String, CodingKey {
        case auth
        case status
        case allowedOutputFormats = "allowed_output_formats"
    }
}

private struct XtreamCategory: Decodable {
    let categoryID: XtreamFlexibleString?
    let categoryName: String?
    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
    }
}

private struct XtreamLiveStream: Decodable {
    let streamID: XtreamFlexibleString?
    let name: String?
    let streamIcon: String?
    let categoryID: XtreamFlexibleString?
    let directSource: String?
    let containerExtension: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case categoryID = "category_id"
        case directSource = "direct_source"
        case containerExtension = "container_extension"
    }
}

private struct XtreamLossyArray<Value: Decodable>: Decodable {
    let values: [Value]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Value] = []
        var inspected = 0
        while !container.isAtEnd, inspected < AppleIPTVClient.maximumChannels * 2 {
            inspected += 1
            let entry = try container.superDecoder()
            if let value = try? Value(from: entry) { result.append(value) }
        }
        values = result
    }
}

private extension String {
    var nonEmptyIPTVString: String? { isEmpty ? nil : self }
}
