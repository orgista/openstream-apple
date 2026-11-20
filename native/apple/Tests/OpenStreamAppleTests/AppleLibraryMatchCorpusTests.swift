import Foundation
import Testing
@testable import OpenStreamApple

struct AppleLibraryMatchCorpusTests {
    private struct Fixture: Decodable, Sendable {
        let name: String
        let parentPath: String
        let identityTitle: String
        let expected: String
    }

    private struct Corpus: Decodable, Sendable {
        let cases: [Fixture]
        let requests: [Request]

        struct Request: Decodable, Sendable {
            let path: String
            let query: [String: String]
            let response: String
        }
    }

    @Test func everyPersistedMissResolvesToItsRecordedTMDBIdentityOrStaysLocal() async throws {
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LibraryMatchCorpus.json")
        let recordedCorpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpus))
        let fixtures = recordedCorpus.cases
        #expect(fixtures.count == 41)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in fixtures {
            let path = fixture.parentPath + "/" + fixture.name
            let item = AppleLibraryItem(sourceID: UUID(), name: fixture.name,
                url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path, sizeBytes: 1)
            #expect(AppleLibraryTitleParser.parse(item).title == fixture.identityTitle)
            let client = AppleTMDBClient { request in
                let url = try #require(request.url)
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? [])
                    .filter { ["query", "year", "first_air_date_year", "external_source"].contains($0.name) }
                    .map { ($0.name, $0.value ?? "") })
                let recorded = try #require(recordedCorpus.requests.first { $0.path == url.path && $0.query == query },
                    "Unrecorded corpus lookup: \(url.path) \(query)")
                return (Data(recorded.response.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            let resolver = AppleLibraryMetadataResolver(directory: root) { parsed, key, _ in
                try await client.librarySearch(parsed, configuration: .init(credential: key))
            }
            let result = try await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "")
            if fixture.expected == "unmatched" {
                #expect(result == nil, "Unmatched local title: \(fixture.name)")
                #expect(AppleLibrarySeries.groups([item]).count == 1)
            } else {
                #expect(result?.mediaID == "tmdb:movie:" + fixture.expected, "Catalog film: \(fixture.name)")
                #expect(result?.posterURL != nil)
            }
        }
    }

    @Test func sameYearFilmNeedsStrongEvidenceToBreakATie() async throws {
        let parsed = AppleLibraryTitleParser.parse(name: "Here.2024.mkv")
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            let body = url.path == "/3/search/movie"
                ? #"{"results":[{"id":1058032,"title":"Here","release_date":"2024-01-17","vote_count":30},{"id":940139,"title":"Here","release_date":"2024-10-30","vote_count":737}]}"#
                : #"{"id":940139,"title":"Here","release_date":"2024-10-30"}"#
            if url.path != "/3/search/movie" { #expect(url.path == "/3/movie/940139") }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let result = try await client.librarySearch(parsed, configuration: .init(credential: "fixture"))
        #expect(result?.mediaID == "tmdb:movie:940139")
    }

    @Test(arguments: [(99, 0), (100, 11), (100, 100)])
    func weakOrTiedEvidenceStaysUnmatched(_ votes: (Int, Int)) async throws {
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            #expect(url.path == "/3/search/movie")
            let body = #"{"results":[{"id":1,"title":"Film","release_date":"2024-01-01","vote_count":\#(votes.0)},{"id":2,"title":"Film","release_date":"2024-01-01","vote_count":\#(votes.1)}]}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let result = try await client.librarySearch(AppleLibraryTitleParser.parse(name: "Film.2024.mkv"), configuration: .init(credential: "fixture"))
        #expect(result == nil)
    }

    @Test func audienceEvidenceRequiresAYearAndIncludesTheThreshold() {
        let feature = AppleCatalogItem(mediaID: "feature", type: "movie", name: "Film", releaseInfo: "2024", voteCount: 100)
        let short = AppleCatalogItem(mediaID: "short", type: "movie", name: "Film", releaseInfo: "2024", voteCount: 10)
        #expect(AppleLibraryMetadataResolver.bestMatch([short, feature],
            parsed: AppleLibraryTitleParser.parse(name: "Film.2024.mkv")) == feature)
        #expect(AppleLibraryMetadataResolver.bestMatch([short, feature],
            parsed: AppleLibraryTitleParser.parse(name: "Film.mkv")) == nil)
    }

    /// Three 2026 films are titled The Odyssey on TMDB; the knockoff's 777
    /// votes kept the 4,459-vote film from matching, so Library drew a text card.
    @Test func aWidelySeenFilmBeatsItsSameNameKnockoff() {
        let film = AppleCatalogItem(mediaID: "tt33764258", type: "movie", name: "The Odyssey", releaseInfo: "2026-07-15", voteCount: 4_459)
        let knockoff = AppleCatalogItem(mediaID: "knockoff", type: "movie", name: "The Odyssey", releaseInfo: "2026-07-03", voteCount: 777)
        let other = AppleCatalogItem(mediaID: "other", type: "movie", name: "The Odyssey", releaseInfo: "2026-07-14", voteCount: 1)
        let parsed = AppleLibraryTitleParser.parse(name: "The.Odyssey.2026.2160p.UHD.Blu-ray.Remux.HEVC.HDR10.DTS-HD.MA.5.1-SPHD.mkv")
        #expect(AppleLibraryMetadataResolver.bestMatch([knockoff, other, film], parsed: parsed) == film)
        let rival = AppleCatalogItem(mediaID: "rival", type: "movie", name: "The Odyssey", releaseInfo: "2026", voteCount: 1_200)
        #expect(AppleLibraryMetadataResolver.bestMatch([rival, film], parsed: parsed) == nil)
    }

    @Test func searchCandidatesCarryAudienceEvidenceForEveryCaller() async throws {
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            let body = #"{"results":[{"id":1,"title":"Film","release_date":"2024-01-01","vote_count":10},{"id":2,"title":"Film","release_date":"2024-01-01","vote_count":100}]}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let candidates = try await client.sharedLinkSearch(title: .init(name: "Film", year: 2024, kind: .movie),
            configuration: .init(credential: "fixture"))
        let winner = try #require(AppleLibraryMetadataResolver.bestMatch(candidates,
            parsed: AppleLibraryTitleParser.parse(name: "Film.2024.mkv")))
        #expect(winner.mediaID == "tmdb:movie:2")
        #expect(winner.voteCount == 100)
        let restored = try JSONDecoder().decode(AppleCatalogItem.self, from: JSONEncoder().encode(winner))
        #expect(restored.voteCount == 100)
        #expect(restored.withMediaID("replacement").voteCount == 100)
        #expect(restored.withoutArtwork.voteCount == 100)
        let legacy = try JSONDecoder().decode(AppleCatalogItem.self,
            from: Data(#"{"mediaID":"legacy","type":"movie","name":"Film"}"#.utf8))
        #expect(legacy.voteCount == nil)
    }

    @Test(arguments: ["Peanuts Bon Voyage Charlie Brown", "Franchise A Journey Across Space"])
    func franchiseFallbackKeepsTheFullQueryFirst(_ name: String) async throws {
        let suffix = name.split(separator: " ").dropFirst().joined(separator: " ")
        let parsed = AppleLibraryTitle(title: name, year: 1980, season: nil, episode: nil, kind: .movie)
        actor Requests {
            var queries: [String] = []
            func append(_ query: String) { queries.append(query) }
        }
        let requests = Requests()
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            let body: String
            if let query {
                await requests.append(query)
                body = query == suffix
                    ? #"{"results":[{"id":1,"title":"\#(suffix) (A Subtitle)","release_date":"1980-01-01"}]}"#
                    : #"{"results":[]}"#
            } else {
                #expect(url.path == "/3/movie/1")
                body = #"{"id":1,"title":"\#(suffix) (A Subtitle)","release_date":"1980-01-01"}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(try await client.librarySearch(parsed, configuration: .init(credential: "fixture"))?.mediaID == "tmdb:movie:1")
        #expect(await requests.queries == [name, name, suffix])
        let wrongYear = AppleCatalogItem(mediaID: "wrong", type: "movie", name: suffix, releaseInfo: "1981")
        #expect(AppleLibraryMetadataResolver.bestMatch([wrongYear], parsed: parsed) == nil)
        #expect(AppleLibraryMetadataResolver.unprefixedTitle(AppleLibraryTitleParser.parse(name: name + ".mkv")) == nil)
        #expect(AppleLibraryMetadataResolver.unprefixedTitle(AppleLibraryTitleParser.parse(name: "Peanuts.Movie.1980.mkv")) == nil)
    }

    @Test func searchOnlyReleasePrefixesKeepTheStoredIdentity() {
        let unpacked = AppleLibraryTitleParser.parse(name: "7a11e36cfd6d49bb97d988f6897a63e8.mkv",
            parentPath: "Library/_UNPACK_Gladiator.2000.Theatrical.Cut.UHD.BluRay.2160p.mkv")
        #expect(unpacked.title == "UNPACK Gladiator")
        #expect(AppleLibraryMetadataResolver.searchQueries(unpacked).first?.title == "Gladiator")
        let peanuts = AppleLibraryTitleParser.parse(name: "Peanuts.Bon.Voyage.Charlie.Brown.1980.1080p.mkv")
        #expect(peanuts.title == "Peanuts Bon Voyage Charlie Brown")
        #expect(AppleLibraryMetadataResolver.searchQueries(peanuts).first?.title == "Peanuts Bon Voyage Charlie Brown")
    }

    @Test func parentheticalSubtitleRequiresTheReleaseYear() {
        let item = AppleCatalogItem(mediaID: "feature", type: "movie",
            name: "Bon Voyage, Charlie Brown (and Don't Come Back!!)", releaseInfo: "1980")
        let parsed = AppleLibraryTitleParser.parse(name: "Bon.Voyage.Charlie.Brown.1980.mkv")
        #expect(AppleLibraryMetadataResolver.bestMatch([item], parsed: parsed) == item)
        #expect(AppleLibraryMetadataResolver.bestMatch([item], parsed: AppleLibraryTitleParser.parse(name: "Bon.Voyage.Charlie.Brown.1990.mkv")) == nil)
        #expect(AppleLibraryMetadataResolver.bestMatch([item], parsed: AppleLibraryTitleParser.parse(name: "Bon.Voyage.Charlie.Brown.mkv")) == nil)
    }

    @Test(arguments: ["Movies/Film (2024)/Extras/clip.mkv", "Movies/Film (2024)/Sample/Film.2024.2160p.x265.mkv",
        "Film.2024-trailer.mkv", "Film.2024.sample.1080p.BluRay.x265-GROUP.mkv",
        "Movies/Film (2024)/Featurettes/Interview.mkv", "Movies/Film (2024)/Behind The Scenes/clip.mkv",
        "Movies/Film (2024)/Deleted Scenes/clip.mkv", "TV/Show/Season 1/Extras/clip.mkv"])
    func supplementalVideosDoNotBecomeLibraryTitles(_ path: String) async throws {
        let item = AppleLibraryItem(sourceID: UUID(), name: (path as NSString).lastPathComponent,
            url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path, sizeBytes: 1)
        #expect(AppleLibraryTitleParser.parse(item).role != .feature)
        #expect(AppleLibraryTitleParser.isSupplemental(item))
        #expect(AppleLibrarySeries.groups([item]).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in
            Issue.record("Supplemental videos must not request metadata")
            return nil
        }
        #expect(try await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "") == nil)
    }

    @Test(arguments: ["Trailer.Park.Boys.S01E01.mkv", "The.Extras.2024.mkv", "Sample.This.2013.mkv"])
    func titleWordsAreNotSupplementalVideoMarkers(_ name: String) {
        #expect(AppleLibraryTitleParser.parse(name: name).role == .feature)
    }

    @Test(arguments: ["TV/Extras/Season 1/Extras.S01E01.mkv",
        "Movies/Extras (2011)/Extras.2011.mkv", "Movies/Extras (2011)/0123456789abcdef.mkv",
        "TV/Featurettes/Season 1/Featurettes.S01E01.mkv",
        "TV/Behind The Scenes/Season 1/Behind.The.Scenes.S01E01.mkv",
        "Movies/Sample/0123456789abcdef.mkv", "Extras/clip.mkv", "Bonus Features/clip.mkv"])
    func titleFoldersAreNeverSupplemental(_ path: String) async throws {
        let source = UUID()
        let name = (path as NSString).lastPathComponent
        let item = AppleLibraryItem(sourceID: source, name: name,
            url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path, sizeBytes: 1)
        let parsed = AppleLibraryTitleParser.parse(item)
        #expect(parsed.role == .feature)
        #expect(AppleLibraryTitleParser.isSupplemental(item) == false)
        #expect(AppleLibrarySeries.groups([item]).count == 1)
        let snapshot = AppleLocalLibraryStore.AppleLibraryGroupSnapshot(
            id: "stored-title", title: parsed.title, year: parsed.year, kind: parsed.kind, items: [
                .init(id: item.id, sourceID: source, name: name, url: item.url,
                    relativePath: path, sizeBytes: 1, addedAt: .distantPast, modifiedAt: nil)
            ])
        #expect(snapshot.restoredGroup(activeSourceIDs: [source])?.items.count == 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = AppleCatalogItem(mediaID: "fixture-title", type: parsed.kind == .show ? "series" : "movie", name: parsed.title)
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in candidate }
        #expect(try await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "") == candidate)
        if path.contains("Movies/Sample/") { #expect(parsed.title == "Sample") }
    }

    @Test func persistedSupplementalGroupsAreFilteredBeforePublication() throws {
        let source = UUID()
        func snapshot(_ name: String) -> AppleLocalLibraryStore.AppleLibraryGroupSnapshot {
            .init(id: "stored-id", title: "Stored title", year: 2024, kind: .movie, items: [
                .init(id: "file-id", sourceID: source, name: name, url: URL(fileURLWithPath: "/fixture/" + name),
                    relativePath: "Movies/" + name, sizeBytes: 1, addedAt: .distantPast, modifiedAt: nil)
            ])
        }
        #expect(snapshot("Film.2024-trailer.mkv").restoredGroup(activeSourceIDs: [source]) == nil)
        let feature = try #require(snapshot("Film.2024.mkv").restoredGroup(activeSourceIDs: [source]))
        #expect(feature.id == "stored-id")
        #expect(feature.parsed.title == "Stored title")
        #expect(snapshot("Film.2024.mkv").restoredGroup(activeSourceIDs: []) == nil)
    }
}
