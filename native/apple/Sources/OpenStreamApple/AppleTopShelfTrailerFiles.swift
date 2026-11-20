import Foundation

/// Saves the Top Shelf carousel pages' trailers from the user's server into
/// the app group's Library/Caches/topshelf-trailers, where the extension
/// hands them to the system as `previewVideoURL`. A server URL carries the
/// user's token and the system plays the preview in its own process, so the
/// file goes on the shelf, never the URL. Only a file the server sends as
/// stored is saved (no conversion), one at a time, each at most
/// `maximumFileBytes` and all together at most `maximumTotalBytes`.
///
/// A file is named after its title alone (`AppleTopShelfTrailerPolicy`), so
/// a page keeps its saved trailer without asking the server again, and a
/// server that is asleep or not signed in yet never costs a saved file.
struct AppleTopShelfTrailerFiles: Sendable {
    typealias Resolve = @Sendable (AppleServerTrailerQuery) async -> AppleServerTrailer?
    /// The size the server reports, without its body; nil when it will not say.
    typealias Measure = @Sendable (URL) async -> Int64?
    /// Saves `source` at `destination` and returns its size.
    typealias Download = @Sendable (_ source: URL, _ destination: URL) async throws -> Int64

    static let maximumFileBytes: Int64 = 250_000_000
    static let maximumTotalBytes: Int64 = 1_000_000_000

    private let resolve: Resolve
    private let measure: Measure
    private let download: Download

    init(resolve: @escaping Resolve = { try? await AppleServerTrailerStore.shared.trailer(for: $0) },
         measure: @escaping Measure = Self.contentLength,
         download: @escaping Download = Self.save) {
        self.resolve = resolve
        self.measure = measure
        self.download = download
    }

    /// What the pages' trailers need: the ones saved already (file name by
    /// item id, within the size budget) and the ones still to fetch.
    struct Plan: Sendable {
        struct Missing: Sendable {
            let id: String
            let name: String
            let title: String
            let url: URL
        }

        var saved: [String: String] = [:]
        var savedBytes: Int64 = 0
        var missing: [Missing] = []

        var wanted: Set<String> { Set(saved.values).union(missing.map(\.name)) }
    }

    func plan(for pages: [(id: String, query: AppleServerTrailerQuery)], in directory: URL,
              cachedOnly: Bool = false) async -> Plan {
        var plan = Plan()
        for page in pages {
            guard !Task.isCancelled else { break }
            if let name = AppleTopShelfTrailerPolicy.savedFile(mediaID: page.query.mediaID, in: directory),
               let size = Self.size(of: directory.appending(path: name)) {
                guard plan.savedBytes + size <= Self.maximumTotalBytes else {
                    // A prefix stays within budget even if artwork failures change which pages are shown.
                    if cachedOnly { break }
                    continue
                }
                plan.saved[page.id] = name
                plan.savedBytes += size
                continue
            }
            guard !cachedOnly, let trailer = await resolve(page.query), trailer.isFile else { continue }
            plan.missing.append(.init(id: page.id, name: AppleTopShelfTrailerPolicy.fileName(mediaID: page.query.mediaID, trailer: trailer),
                                      title: page.query.title, url: trailer.url))
        }
        return plan
    }

    /// Fetches the plan's missing trailers one at a time, while the budget
    /// lasts; the file name of each one saved, by item id.
    func fetchMissing(_ plan: Plan, in directory: URL) async -> [String: String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        var total = plan.savedBytes
        for page in plan.missing {
            guard !Task.isCancelled else { break }
            guard let size = await measure(page.url), size <= Self.maximumFileBytes,
                  total + size <= Self.maximumTotalBytes else {
                appleTrace("top shelf trailer skipped for \(page.title): size unknown or too large")
                continue
            }
            do {
                total += try await download(page.url, directory.appending(path: page.name))
                names[page.id] = page.name
            } catch {
                appleTrace("top shelf trailer not saved for \(page.title): \((error as? URLError)?.code.rawValue ?? -1)")
            }
        }
        return names
    }

    /// Deletes every saved trailer no page uses any more.
    func removeAll(in directory: URL, except kept: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Asks for the first byte and reads the size off the reply's headers;
    /// the body is never read, so a server that ignores the range costs
    /// nothing either.
    @Sendable static func contentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        bytes.task.cancel()
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        return http.statusCode == 200 && http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    @Sendable static func save(_ source: URL, to destination: URL) async throws -> Int64 {
        let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: source, timeoutInterval: 60))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let size = size(of: temporary), size > 0, size <= maximumFileBytes else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return size
    }
}

/// Runs the Top Shelf's trailer downloads apart from the publish that asked
/// for them: a publish comes every few seconds while the app settles and
/// would cancel a 100 MB download each time. A new set of missing files
/// replaces the running one; the same set leaves it alone.
actor AppleTopShelfTrailerDownloads {
    static let shared = AppleTopShelfTrailerDownloads()

    private var running: (names: Set<String>, task: Task<Void, Never>)?

    /// `onSaved` gets the file name of each trailer saved, by item id.
    func fetch(_ plan: AppleTopShelfTrailerFiles.Plan, with files: AppleTopShelfTrailerFiles, in directory: URL,
               onSaved: @escaping @Sendable ([String: String]) async -> Void) {
        let names = Set(plan.missing.map(\.name))
        guard running?.names != names else { return }
        running?.task.cancel()
        running = names.isEmpty ? nil : (names, Task {
            let saved = await files.fetchMissing(plan, in: directory)
            if !Task.isCancelled, !saved.isEmpty { await onSaved(saved) }
            await self.finished(names)
        })
    }

    /// A finished set is asked for again by the next publish that still misses it.
    private func finished(_ names: Set<String>) {
        if running?.names == names { running = nil }
    }

    /// Stops the running downloads and waits for them to end, so nothing
    /// lands on disk after a Top Shelf opt-out.
    func cancel() async {
        guard let running else { return }
        self.running = nil
        running.task.cancel()
        await running.task.value
    }

    /// Waits for the running downloads (tests).
    func finish() async {
        await running?.task.value
    }
}
