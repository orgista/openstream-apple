import Foundation

/// The Top 10 row on Discover: TMDB's most popular movies and shows of the
/// week (credited with the TMDB notice in Settings › About), each with its
/// full TMDB details. Kept on disk so the next launch draws the row from its
/// first frame; asked again after `refreshInterval`.
actor AppleTop10Store {
    struct Chart: Codable, Equatable, Sendable {
        var items: [AppleCatalogItem]
        var fetchedAt: Date
    }

    typealias Fetch = @Sendable (_ type: String, AppleTMDBConfiguration) async throws -> [AppleCatalogItem]

    static let shared = AppleTop10Store()
    static let refreshInterval: TimeInterval = 6 * 3600
    /// The kept chart, in `Caches/OpenStream`.
    static let fileName = "top10-tmdb-v2.json"

    private let fileURL: URL
    private let fetch: Fetch
    private var chart: Chart?
    private var isLoaded = false

    init(fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenStream", directoryHint: .isDirectory).appending(path: fileName),
         fetch: @escaping Fetch = { try await AppleTMDBClient().weeklyTop10(type: $0, configuration: $1) }) {
        self.fileURL = fileURL
        self.fetch = fetch
    }

    /// The chart an earlier launch kept, without asking TMDB.
    func stored() -> Chart? {
        loadIfNeeded()
        return chart
    }

    /// The kept chart while it is fresh, else TMDB's current one.
    func latest(configuration: AppleTMDBConfiguration, now: Date = .now) async throws -> Chart {
        loadIfNeeded()
        if let chart, now.timeIntervalSince(chart.fetchedAt) < Self.refreshInterval { return chart }
        let fresh = Chart(items: try await fetch("all", configuration), fetchedAt: now)
        chart = fresh
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(fresh).write(to: fileURL, options: .atomic)
        return fresh
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        chart = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Chart.self, from: $0) }
    }
}
