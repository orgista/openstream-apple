import Foundation

public struct AppleNetflixTop10Entry: Sendable, Equatable {
    public let rank: Int
    public let title: String
    public let seasonTitle: String?
    public let category: String

    public init(rank: Int, title: String, seasonTitle: String?, category: String) {
        self.rank = rank
        self.title = title
        self.seasonTitle = seasonTitle
        self.category = category
    }
}

public struct AppleNetflixTop10Week: Sendable, Equatable {
    public let week: Date
    public let films: [AppleNetflixTop10Entry]
    public let tv: [AppleNetflixTop10Entry]
    public let isStale: Bool

    public init(week: Date, films: [AppleNetflixTop10Entry], tv: [AppleNetflixTop10Entry], isStale: Bool = false) {
        self.week = week
        self.films = films
        self.tv = tv
        self.isStale = isStale
    }
}

public actor AppleNetflixTop10Client {
    private let session: URLSession
    private let country: String
    private var lastSnapshot: AppleNetflixTop10Week?
    private var lastFetchTime: Date?
    
    public init(session: URLSession, country: String = "US") {
        self.session = session
        self.country = country.uppercased()
    }
    
    public func latestWeek() async throws -> AppleNetflixTop10Week {
        let now = Date()
        
        if let snapshot = lastSnapshot, let fetchTime = lastFetchTime, now.timeIntervalSince(fetchTime) < 4 * 3600 {
            let stale = now.timeIntervalSince(fetchTime) > 30 * 3600
            if snapshot.isStale == stale {
                return snapshot
            } else {
                let updated = AppleNetflixTop10Week(week: snapshot.week, films: snapshot.films, tv: snapshot.tv, isStale: stale)
                lastSnapshot = updated
                return updated
            }
        }
        
        guard let url = URL(string: "https://www.netflix.com/tudum/top10/data/all-weeks-countries.tsv") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Mozilla/5.0 (compatible; OpenStreamTop10/0.1; +https://github.com/cyberbanksy/OpenStream)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.netflix.com/tudum/top10/", forHTTPHeaderField: "Referer")
        
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            var parser = AppleNetflixTop10Parser(country: country)
            var line: [UInt8] = []
            line.reserveCapacity(1024)
            var received = 0
            for try await byte in bytes {
                received += 1
                guard received <= 64 * 1024 * 1024, line.count < 32 * 1024 else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                if byte == 10 {
                    try parser.consume(String(decoding: line, as: UTF8.self))
                    line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
            if !line.isEmpty { try parser.consume(String(decoding: line, as: UTF8.self)) }
            try Task.checkCancellation()
            let result = try parser.finish()

            let newSnapshot = AppleNetflixTop10Week(
                week: result.week,
                films: result.films,
                tv: result.tv,
                isStale: false
            )
            
            lastSnapshot = newSnapshot
            lastFetchTime = now
            return newSnapshot
            
        } catch {
            try Task.checkCancellation()
            if let snapshot = lastSnapshot {
                let stale = now.timeIntervalSince(lastFetchTime ?? .distantPast) > 30 * 3600
                let fallback = AppleNetflixTop10Week(week: snapshot.week, films: snapshot.films, tv: snapshot.tv, isStale: stale)
                lastSnapshot = fallback
                return fallback
            }
            throw error
        }
    }
    
}

/// Keeps only the newest country's twenty ranked entries while reading a TSV.
/// The feed is not assumed to be sorted by week or country.
struct AppleNetflixTop10Parser {
    private var columns: [String: Int] = [:]
    private var newestWeek = ""
    private var films: [Int: AppleNetflixTop10Entry] = [:]
    private var shows: [Int: AppleNetflixTop10Entry] = [:]
    let country: String

    init(country: String) { self.country = country }

    mutating func consume(_ line: String) throws {
        guard !line.isEmpty else { return }
        let cells = line.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        if columns.isEmpty {
            for (index, name) in cells.enumerated() { columns[name] = index }
            guard ["country_iso2", "week", "category", "weekly_rank", "show_title", "season_title"]
                .allSatisfy({ columns[$0] != nil }) else { throw URLError(.cannotParseResponse) }
            return
        }
        func value(_ key: String) -> String {
            guard let index = columns[key], cells.indices.contains(index) else { return "" }
            return cells[index]
        }
        guard value("country_iso2").uppercased() == country.uppercased() else { return }
        let week = value("week")
        guard week.count == 10, week >= newestWeek,
              let rank = Int(value("weekly_rank")), (1...10).contains(rank),
              ["Films", "TV"].contains(value("category")) else { return }
        let title = value("show_title").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        if week > newestWeek { newestWeek = week; films = [:]; shows = [:] }
        let season = value("season_title").trimmingCharacters(in: .whitespaces)
        let isMovie = value("category") == "Films"
        let entry = AppleNetflixTop10Entry(rank: rank, title: title,
            seasonTitle: season.isEmpty || season == "N/A" ? nil : season,
            category: isMovie ? "movie" : "series")
        if isMovie { if films[rank] == nil { films[rank] = entry } }
        else if shows[rank] == nil { shows[rank] = entry }
    }

    func finish() throws -> AppleNetflixTop10Week {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let week = formatter.date(from: newestWeek), formatter.string(from: week) == newestWeek else {
            throw URLError(.cannotParseResponse)
        }
        return AppleNetflixTop10Week(week: week,
            films: (1...10).compactMap { films[$0] }, tv: (1...10).compactMap { shows[$0] })
    }
}
