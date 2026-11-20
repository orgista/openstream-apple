import Foundation

/// Xtream panels do not consistently implement offset paging. Request one category at a time,
/// decode away from MainActor, and page the resulting category locally. Never prefetch details.
public actor AppleXtreamLibraryClient {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loader: Loader
    private let directory: URL
    private struct Cached: Codable { let storedAt: Date; let data: Data }

    public init(directory: URL? = nil, loader: @escaping Loader = AppleXtreamLibraryClient.liveLoader) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenStream").appendingPathComponent("XtreamLibrary")
        self.loader = loader
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: AppleXtreamLibraryPolicy.maximumBytes)
    }

    private func request(base: URL, credentials: AppleIPTVCredentials, action: String,
                         parameter: String? = nil, argument: String? = nil, force: Bool = false) async throws -> Any {
        try Task.checkCancellation()
        let key = AppleXtreamLibraryPolicy.cacheKey(base: base, credentials: credentials, action: action, argument: argument)
        let file = directory.appendingPathComponent(key + ".json")
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let cached: Cached? = size <= AppleXtreamLibraryPolicy.maximumBytes * 2
            ? (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) } : nil
        if !force, let cached, AppleXtreamLibraryPolicy.isFresh(storedAt: cached.storedAt, now: Date()) {
            return try JSONSerialization.jsonObject(with: cached.data)
        }
        guard var components = URLComponents(url: try AppleIPTVClient.xtreamAPIURL(baseURL: base, credentials: credentials, action: action), resolvingAgainstBaseURL: false) else { throw AppleIPTVError.invalidEndpoint }
        if let parameter, let argument { components.queryItems?.append(URLQueryItem(name: parameter, value: argument)) }
        guard let url = components.url else { throw AppleIPTVError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await loader(request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppleXtreamLibraryError.unavailable }
            guard data.count <= AppleXtreamLibraryPolicy.maximumBytes else { throw AppleXtreamLibraryError.tooLarge }
            let json: Any
            do { json = try JSONSerialization.jsonObject(with: data) }
            catch { throw AppleXtreamLibraryError.invalidResponse }
            if action == "get_vod_info" || action == "get_series_info" {
                guard let object = json as? [String: Any], object["info"] is [String: Any] else { throw AppleXtreamLibraryError.invalidResponse }
            } else {
                guard json is [Any] else { throw AppleXtreamLibraryError.invalidResponse }
            }
            // Do not cache error envelopes as a valid empty library.
            if let object = json as? [String: Any], object["error"] != nil { throw AppleXtreamLibraryError.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(Cached(storedAt: Date(), data: data)) {
                try? encoded.write(to: file, options: .atomic)
                trimCache()
            }
            return json
        } catch is CancellationError { throw CancellationError() }
        catch AppleBoundedHTTPError.responseTooLarge { throw AppleXtreamLibraryError.tooLarge }
        catch let error as AppleXtreamLibraryError { throw error }
        catch { throw AppleXtreamLibraryError.unavailable }
    }

    public func categories(base: URL, credentials: AppleIPTVCredentials, kind: AppleXtreamReference.Kind,
                           force: Bool = false) async throws -> [AppleXtreamCategory] {
        let json = try await request(base: base, credentials: credentials,
            action: kind == .movie ? "get_vod_categories" : "get_series_categories", force: force)
        guard let values = json as? [Any] else { throw AppleXtreamLibraryError.invalidResponse }
        let rows = values.compactMap { $0 as? [String: Any] }
        guard values.count <= 2_000 else { throw AppleXtreamLibraryError.tooLarge }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = scalar(row["category_id"]), AppleXtreamLibraryPolicy.validID(id), seen.insert(id).inserted else { return nil }
            return AppleXtreamCategory(id: id, name: scalar(row["category_name"]) ?? "Other")
        }
    }

    public func titles(base: URL, credentials: AppleIPTVCredentials, kind: AppleXtreamReference.Kind,
                       categoryID: String?, force: Bool = false) async throws -> [AppleXtreamTitle] {
        let json = try await request(base: base, credentials: credentials,
            action: kind == .movie ? "get_vod_streams" : "get_series", parameter: "category_id", argument: categoryID, force: force)
        guard let values = json as? [Any] else { throw AppleXtreamLibraryError.invalidResponse }
        let rows = values.compactMap { $0 as? [String: Any] }
        guard values.count <= AppleXtreamLibraryPolicy.maximumTitles else { throw AppleXtreamLibraryError.tooLarge }
        var result: [AppleXtreamTitle] = []
        var seen = Set<String>()
        for row in rows {
            try Task.checkCancellation()
            guard let title = title(row, kind: kind), seen.insert(title.id).inserted else { continue }
            result.append(title)
        }
        return result
    }

    public func detail(base: URL, credentials: AppleIPTVCredentials, title: AppleXtreamTitle) async throws -> AppleXtreamDetail {
        let isMovie = title.kind == .movie
        let json = try await request(base: base, credentials: credentials,
            action: isMovie ? "get_vod_info" : "get_series_info", parameter: isMovie ? "vod_id" : "series_id", argument: title.providerID)
        guard let object = json as? [String: Any], let info = object["info"] as? [String: Any] else { throw AppleXtreamLibraryError.invalidResponse }
        var merged = info
        let movie = object["movie_data"] as? [String: Any] ?? [:]
        merged[isMovie ? "stream_id" : "series_id"] = title.providerID
        merged["name"] = scalar(info["name"]) ?? title.name
        merged["container_extension"] = movie["container_extension"] ?? title.container
        let enriched = self.title(merged, kind: title.kind, fallback: title) ?? title
        var episodes: [AppleXtreamEpisode] = []
        var seen = Set<String>()
        if !isMovie, let seasons = object["episodes"] as? [String: Any] {
            for (key, value) in seasons {
                guard let rows = value as? [[String: Any]] else { continue }
                for row in rows {
                    try Task.checkCancellation()
                    guard episodes.count < 20_000 else { throw AppleXtreamLibraryError.tooLarge }
                    guard let id = scalar(row["id"]), AppleXtreamLibraryPolicy.validID(id), seen.insert(id).inserted,
                          let number = scalar(row["episode_num"]).flatMap(Int.init), number > 0,
                          let season = scalar(row["season"]).flatMap(Int.init) ?? Int(key), season >= 0 else { continue }
                    episodes.append(AppleXtreamEpisode(providerID: id, title: scalar(row["title"]) ?? "Episode \(number)",
                        season: season, number: number, container: scalar(row["container_extension"]) ?? "mp4"))
                }
            }
        }
        return AppleXtreamDetail(title: enriched, episodes: episodes.sorted {
            ($0.season, $0.number, $0.providerID) < ($1.season, $1.number, $1.providerID)
        })
    }

    private func trimCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        for entry in entries where size > 256 * 1_024 * 1_024 || count > 1_024 {
            try? FileManager.default.removeItem(at: entry.0)
            size -= entry.1
            count -= 1
        }
    }

    private func scalar(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func artwork(_ value: Any?) -> URL? {
        let raw = (value as? [String])?.first ?? scalar(value)
        guard let raw, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    private func title(_ row: [String: Any], kind: AppleXtreamReference.Kind, fallback: AppleXtreamTitle? = nil) -> AppleXtreamTitle? {
        guard let id = scalar(row[kind == .movie ? "stream_id" : "series_id"]), AppleXtreamLibraryPolicy.validID(id),
              let name = scalar(row["name"]), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AppleXtreamTitle(providerID: id, kind: kind, name: String(name.prefix(200)),
            categoryID: scalar(row["category_id"]) ?? fallback?.categoryID,
            poster: artwork(row["stream_icon"] ?? row["cover"] ?? row["movie_image"]) ?? fallback?.poster,
            backdrop: artwork(row["backdrop_path"]) ?? fallback?.backdrop,
            plot: scalar(row["plot"]) ?? scalar(row["description"]) ?? fallback?.plot,
            year: scalar(row["year"]).flatMap(Int.init) ?? scalar(row["releasedate"] ?? row["releaseDate"]).flatMap { Int($0.prefix(4)) } ?? fallback?.year,
            rating: scalar(row["rating"]).flatMap(Double.init) ?? fallback?.rating,
            container: scalar(row["container_extension"]) ?? fallback?.container,
            tmdbID: scalar(row["tmdb_id"] ?? row["tmdb"]) ?? fallback?.tmdbID)
    }
}
