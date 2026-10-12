import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleMediaServerLibraryTests")
struct AppleMediaServerLibraryTests {
    let baseURL = URL(string: "https://fixture.example/emby/")!
    var session: AppleMediaServerSession {
        AppleMediaServerSession(kind: .emby, baseURL: baseURL, accessToken: "token_123", userID: "user_456")
    }

    @Test("libraries decode")
    func testLibraries() async throws {
        let client = AppleMediaServerClient(loader: { req in
            #expect(req.url?.absoluteString == "https://fixture.example/emby/" + "Users/user_456/Views")
            #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == "token_123")
            let json = """
            {
                "Items": [
                    { "Id": "1", "Name": "M", "CollectionType": "movies" },
                    { "Id": "2", "Name": "T", "CollectionType": "tvshows" },
                    { "Id": "3", "Name": "O", "CollectionType": "boxsets" },
                    { "Id": "4", "Name": "U" }
                ]
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let libs = try await client.libraries(session: session)
        #expect(libs.count == 4)
        #expect(libs[0].collectionType == .movies)
        #expect(libs[1].collectionType == .tvshows)
        #expect(libs[2].collectionType == .other)
        #expect(libs[3].collectionType == .other)
    }

    @Test("items queries and decoding")
    func testItems() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let url = req.url!
            #expect(url.path == "/emby/" + "Users/user_456/Items")
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let qi = comps.queryItems!
            #expect(qi.contains(URLQueryItem(name: "ParentId", value: "p1")))
            #expect(qi.contains(URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")))
            #expect(qi.contains(URLQueryItem(name: "Fields", value: "Overview,ProductionYear,Genres,ProviderIds,CommunityRating,RunTimeTicks,SeriesId,SeasonId")))
            #expect(qi.contains(URLQueryItem(name: "Limit", value: "10")))
            
            let json = """
            {
                "Items": [
                    {
                        "Id": "i1",
                        "Name": "N1",
                        "Type": "Movie",
                        "RunTimeTicks": 2400210000,
                        "ImageTags": { "Primary": "abc" },
                        "ProviderIds": { "Tmdb": "10378" },
                        "UserData": {
                            "PlaybackPositionTicks": 600000000
                        }
                    }
                ],
                "TotalRecordCount": 1
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let page = try await client.items(session: session, parentID: "p1", includeTypes: [.movie, .series], limit: 10)
        #expect(page.totalRecordCount == 1)
        #expect(page.items.count == 1)
        let item = page.items[0]
        #expect(item.id == "i1")
        #expect(item.type == .movie)
        #expect(item.runtimeSeconds == 240.021)
        #expect(item.primaryImageTag == "abc")
        #expect(item.tmdbID == "10378")
        #expect(item.userData?.positionSeconds == 60.0)
    }

    @Test("latest bare array decode")
    func testLatest() async throws {
        let client = AppleMediaServerClient(loader: { req in
            #expect(req.url?.path == "/emby/" + "Users/user_456/Items/Latest")
            let json = """
            [
                { "Id": "i1", "Name": "N1", "Type": "Episode" }
            ]
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let items = try await client.latest(session: session, parentID: nil)
        #expect(items.count == 1)
        #expect(items[0].type == .episode)
    }

    @Test("resume path and MediaTypes")
    func testResume() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let url = req.url!
            #expect(url.path == "/emby/" + "Users/user_456/Items/Resume")
            let qi = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(qi.contains(URLQueryItem(name: "MediaTypes", value: "Video")))
            
            let json = """
            { "Items": [], "TotalRecordCount": 0 }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        _ = try await client.resume(session: session)
    }

    @Test("seasons and episodes paths + IndexNumber/ParentIndexNumber")
    func testSeasonsAndEpisodes() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let url = req.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path == "/emby/Shows/s1/Seasons" {
                let json = """
                {
                    "Items": [
                        { "Id": "sea1", "Name": "Season 1", "Type": "Season", "IndexNumber": 1 }
                    ]
                }
                """
                return (json.data(using: .utf8)!, ok)
            } else if url.path == "/emby/Shows/s1/Episodes" {
                let json = """
                {
                    "Items": [
                        { "Id": "ep1", "Name": "Ep 1", "Type": "Episode", "IndexNumber": 1, "ParentIndexNumber": 1 }
                    ]
                }
                """
                return (json.data(using: .utf8)!, ok)
            }
            Issue.record("Unexpected \(url.path)")
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        
        let seasons = try await client.seasons(session: session, seriesID: "s1")
        #expect(seasons.count == 1)
        #expect(seasons[0].indexNumber == 1)
        
        let episodes = try await client.episodes(session: session, seriesID: "s1", seasonID: "sea1")
        #expect(episodes.count == 1)
        #expect(episodes[0].indexNumber == 1)
        #expect(episodes[0].parentIndexNumber == 1)
    }

    @Test("playbackInfo POST body and MediaSource decode")
    func testPlaybackInfo() async throws {
        let client = AppleMediaServerClient(loader: { req in
            #expect(req.url?.path == "/emby/Items/i1/PlaybackInfo")
            #expect(req.httpMethod == "POST")
            
            let body = try! JSONDecoder().decode([String: AnyValue].self, from: req.httpBody!)
            #expect(body["UserId"]?.value as? String == "user_456")
            
            let json = """
            {
                "PlaySessionId": "ps1",
                "MediaSources": [
                    {
                        "Id": "ms1",
                        "Container": "mkv",
                        "SupportsDirectPlay": true
                    }
                ]
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let info = try await client.playbackInfo(session: session, itemID: "i1")
        #expect(info.playSessionID == "ps1")
        #expect(info.mediaSources.count == 1)
        #expect(info.mediaSources[0].supportsDirectPlay == true)
        #expect(info.mediaSources[0].container == "mkv")
    }

    @Test("directStreamURL exact string")
    func testDirectStreamURL() throws {
        let client = AppleMediaServerClient()
        let url = try client.directStreamURL(session: session, itemID: "10", mediaSourceID: "mediasource_10", container: "mkv")
        #expect(url.absoluteString == "https://fixture.example/emby/Videos/10/stream.mkv?static=true&mediaSourceId=mediasource_10&api_key=token_123")
    }

    @Test("imageURL with tag and maxWidth")
    func testImageURL() throws {
        let client = AppleMediaServerClient()
        let url = try client.imageURL(session: session, itemID: "i1", type: .primary, tag: "t1", maxWidth: 400)
        #expect(url.absoluteString.contains("/emby/Items/i1/Images/Primary"))
        #expect(url.absoluteString.contains("tag=t1"))
        #expect(url.absoluteString.contains("maxWidth=400"))
    }

    @Test("progress bodies and 204 does not throw")
    func testProgress() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let body = try! JSONDecoder().decode([String: AnyValue].self, from: req.httpBody!)
            let ticks = (body["PositionTicks"]?.value as? Int) ?? Int(body["PositionTicks"]?.value as? Int64 ?? 0)
            #expect(ticks == 600_000_000)
            if req.url?.path.hasSuffix("/Progress") == true {
                #expect(body["IsPaused"]?.value as? Bool == true)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        
        try await client.reportPlaybackStart(session: session, itemID: "i1", mediaSourceID: "ms1", playSessionID: "ps1", positionSeconds: 60)
        try await client.reportPlaybackProgress(session: session, itemID: "i1", mediaSourceID: "ms1", playSessionID: "ps1", positionSeconds: 60, isPaused: true)
        try await client.reportPlaybackStopped(session: session, itemID: "i1", mediaSourceID: "ms1", playSessionID: "ps1", positionSeconds: 60)
    }
}

// Helper for dynamic decoding in tests
enum AnyValue: Decodable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null
    
    var value: Any? {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .int64(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return nil
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Int64.self) { self = .int64(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyValue") }
    }
}
