import Foundation
import Testing
@testable import OpenStreamApple

@Test func arrEndpointPolicyAllowsHTTPSAndPrivateLiteralHTTPOnly() throws {
    #expect(AppleArrEndpointPolicy.isAllowed("https://radarr.example"))
    #expect(AppleArrEndpointPolicy.isAllowed("https://radarr.example/openstream/"))
    #expect(AppleArrEndpointPolicy.isAllowed("http://192.168.1.20:7878"))
    #expect(AppleArrEndpointPolicy.isAllowed("http://10.0.0.20:8989"))
    #expect(AppleArrEndpointPolicy.isAllowed("http://[fd00::20]:7878"))
    #expect(!AppleArrEndpointPolicy.isAllowed("http://radarr.example"))
    #expect(!AppleArrEndpointPolicy.isAllowed("http://8.8.8.8:7878"))
    #expect(!AppleArrEndpointPolicy.isAllowed("ftp://192.168.1.20"))
    #expect(!AppleArrEndpointPolicy.isAllowed("https://user:pass@radarr.example"))
    #expect(!AppleArrEndpointPolicy.isAllowed("https://radarr.example?apikey=secret"))
    #expect(!AppleArrEndpointPolicy.isAllowed("https://radarr.example/#status"))

    #expect(try AppleArrEndpointPolicy.normalize(" https://radarr.example/openstream/ ").absoluteString ==
        "https://radarr.example/openstream")
}

@Test func arrClientUsesNativeStatusEndpointAndAPIKeyHeader() async throws {
    let client = AppleArrClient { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://radarr.example/openstream/api/v3/system/status")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "radarr-secret")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OpenStream/1.0 Apple")
        #expect(request.timeoutInterval == 15)

        let data = Data(#"{"appName":"Radarr","version":"5.7.0","instanceName":"Movies"}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let status = try await client.test(
        kind: .radarr,
        baseURL: "https://radarr.example/openstream/",
        apiKey: "  radarr-secret  "
    )

    #expect(status == AppleArrStatus(appName: "Radarr", version: "5.7.0", instanceName: "Movies"))
}

@Test func arrClientUsesSonarrStatusEndpointAndBoundsDisplayedFields() async throws {
    let client = AppleArrClient { request in
        #expect(request.url?.path == "/api/v3/system/status")
        let payload = """
        {
          "appName": "",
          "version": "\(String(repeating: "1", count: 60))",
          "instanceName": "\(String(repeating: "S", count: 100))"
        }
        """
        return (
            Data(payload.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let status = try await client.test(
        kind: .sonarr,
        baseURL: "https://sonarr.example",
        apiKey: "sonarr-secret"
    )

    #expect(status.appName == "Sonarr")
    #expect(status.version.count == 40)
    #expect(status.instanceName.count == 80)
}

@Test func arrClientRejectsInvalidEndpointAndHeaderValueBeforeLoading() async {
    let client = AppleArrClient { _ in
        Issue.record("The loader must not run for invalid connection settings.")
        throw URLError(.badURL)
    }

    await #expect(throws: AppleArrClientError.invalidEndpoint) {
        try await client.test(kind: .radarr, baseURL: "http://public.example:7878", apiKey: "secret")
    }
    await #expect(throws: AppleArrClientError.invalidAPIKey) {
        try await client.test(kind: .sonarr, baseURL: "https://sonarr.example", apiKey: "secret\nheader")
    }
    #expect(!AppleArrClient.isValidAPIKey("secret\rheader"))
    #expect(!AppleArrClient.isValidAPIKey(""))
}

@Test func arrClientEnqueuesMovieWithSearchOptionsAndSafeHeaders() async throws {
    let client = AppleArrClient { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://radarr.example/api/v3/movie")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "radarr-secret")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OpenStream/1.0 Apple")
        #expect(request.timeoutInterval == 20)

        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["title"] as? String == "Arrival")
        #expect(payload["year"] as? Int == 2016)
        #expect(payload["qualityProfileId"] as? Int == 7)
        #expect(payload["rootFolderPath"] as? String == "/media/movies")
        #expect(payload["tmdbId"] as? Int == 329865)
        #expect(payload["imdbId"] == nil)
        let addOptions = try #require(payload["addOptions"] as? [String: Any])
        #expect(addOptions["searchForMovie"] as? Bool == true)

        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }

    try await client.enqueue(
        kind: .radarr,
        baseURL: "https://radarr.example",
        apiKey: "radarr-secret",
        title: "Arrival",
        year: 2016,
        mediaID: "tmdb:329865",
        rootFolderPath: " /media/movies ",
        qualityProfileID: "7"
    )
}

@Test func arrClientRejectsIncompleteQueueConfigurationBeforeLoading() async {
    let client = AppleArrClient { _ in
        Issue.record("The loader must not run for incomplete queue settings.")
        throw URLError(.badURL)
    }

    await #expect(throws: AppleArrClientError.invalidQueueConfiguration) {
        try await client.enqueue(
            kind: .sonarr,
            baseURL: "https://sonarr.example",
            apiKey: "sonarr-secret",
            title: "The Expanse",
            year: 2015,
            mediaID: "tvdb:280619",
            rootFolderPath: "",
            qualityProfileID: ""
        )
    }
}

@Test func arrClientRejectsRedirectsAndChangedResponseOrigins() async {
    let redirected = AppleArrClient { request in
        (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://other.example/api/v3/system/status"]
            )!
        )
    }
    await #expect(throws: AppleArrClientError.redirected) {
        try await redirected.test(kind: .radarr, baseURL: "https://radarr.example", apiKey: "secret")
    }

    let changedOrigin = AppleArrClient { _ in
        let url = URL(string: "https://other.example/api/v3/system/status")!
        return (
            Data(#"{"appName":"Radarr"}"#.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    await #expect(throws: AppleArrClientError.redirected) {
        try await changedOrigin.test(kind: .radarr, baseURL: "https://radarr.example", apiKey: "secret")
    }
}

@Test func arrClientRejectsOversizedFailedAndMalformedResponses() async {
    let oversized = AppleArrClient { request in
        (
            Data(repeating: 0, count: AppleArrClient.maximumResponseBytes + 1),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    await #expect(throws: AppleArrClientError.responseTooLarge) {
        try await oversized.test(kind: .radarr, baseURL: "https://radarr.example", apiKey: "secret")
    }

    let failed = AppleArrClient { request in
        (
            Data(),
            HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        )
    }
    await #expect(throws: AppleArrClientError.requestFailed(401)) {
        try await failed.test(kind: .sonarr, baseURL: "https://sonarr.example", apiKey: "secret")
    }

    let malformed = AppleArrClient { request in
        (
            Data("[]".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    await #expect(throws: AppleArrClientError.invalidResponse) {
        try await malformed.test(kind: .sonarr, baseURL: "https://sonarr.example", apiKey: "secret")
    }
}

@Test func arrLibraryLoadsDownloadedMoviesAndSeriesIntoOpaqueMediaRecords() async throws {
    let client = AppleArrClient { request in
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "arr-secret")
        #expect(request.url?.absoluteString == "https://radarr.example/api/v3/movie")
        let data = Data(#"[{"id":42,"title":"Arrival","year":2016,"overview":"First contact.","imdbId":"tt2543164","tmdbId":329865,"hasFile":true,"images":[{"coverType":"poster","remoteUrl":"https://image.example/arrival.jpg"}]}]"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let values = try await client.library(
        kind: .radarr,
        baseURL: "https://radarr.example",
        apiKey: "arr-secret"
    )
    let value = try #require(values.first)
    #expect(value.title == "Arrival")
    #expect(value.canonicalID == "tt2543164")
    #expect(value.hasFile)
    #expect(value.artworkURL == URL(string: "https://image.example/arrival.jpg"))
    #expect(!value.id.contains("radarr.example"))

    let instanceID = try #require(AppleArrInstanceIdentity.id(kind: .radarr, baseURL: "https://radarr.example"))
    let indexed = try #require(AppleMediaIngestion.arrRecords(instanceID: instanceID, values: values).first)
    #expect(indexed.kind == .movie)
    #expect(indexed.isPrivate)
    #expect(indexed.availability.first?.capability == .gateway)
    #expect(!indexed.availability.first!.itemReference.contains("Arrival"))
}

@Test func arrClientFindsExactTitleAndYearForMoviesAndSeries() async throws {
    let client = AppleArrClient { request in
        let data: Data
        if request.url?.path.hasSuffix("/movie") == true {
            data = Data(#"[{"id":1,"title":"Amelie","year":2001,"tmdbId":194},{"id":2,"title":"Amélie","year":2002,"tmdbId":195}]"#.utf8)
        } else {
            data = Data(#"[{"id":3,"title":"The Expanse","year":2015,"tvdbId":280619}]"#.utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    let movie = try await client.exactMatch(
        kind: .radarr,
        baseURL: "https://radarr.example",
        apiKey: "key",
        title: "  AMELIE! ",
        year: 2001
    )
    let series = try await client.exactMatch(
        kind: .sonarr,
        baseURL: "https://sonarr.example",
        apiKey: "key",
        title: "The-Expanse",
        year: 2015
    )
    let wrongYear = try await client.exactMatch(
        kind: .radarr,
        baseURL: "https://radarr.example",
        apiKey: "key",
        title: "Amelie",
        year: 1999
    )

    #expect(movie?.canonicalID == "tmdb:194")
    #expect(series?.canonicalID == "tvdb:280619")
    #expect(wrongYear == nil)
}

@Test func arrClientLoadsRootFoldersAndQualityProfilesForBothKinds() async throws {
    let client = AppleArrClient { request in
        let data: Data
        switch request.url?.path {
        case "/api/v3/rootfolder":
            data = Data(#"[{"id":1,"path":" /media/library ","freeSpace":987654},{"id":0,"path":""}]"#.utf8)
        case "/api/v3/qualityprofile":
            data = Data(#"[{"id":7,"name":" HD-1080p "},{"id":-1,"name":"invalid"}]"#.utf8)
        default:
            Issue.record("Unexpected ARR queue-options endpoint")
            data = Data("[]".utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    for (kind, host) in [(AppleArrKind.radarr, "radarr.example"), (.sonarr, "sonarr.example")] {
        let options = try await client.queueOptions(
            kind: kind,
            baseURL: "https://\(host)",
            apiKey: "key"
        )
        #expect(options.rootFolders == [AppleArrRootFolder(id: 1, path: "/media/library", freeSpace: 987654)])
        #expect(options.qualityProfiles == [AppleArrQualityProfile(id: 7, name: "HD-1080p")])
    }
}

private actor ArrDuplicateFixture {
    private var present: Set<String> = []
    private var posts: [String: Int] = [:]

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let kind = request.url?.path.hasSuffix("/movie") == true ? "radarr" : "sonarr"
        if request.httpMethod == "POST" {
            present.insert(kind)
            posts[kind, default: 0] += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let data: Data
        if present.contains(kind) {
            data = kind == "radarr"
                ? Data(#"[{"id":1,"title":"Arrival","year":2016,"tmdbId":329865}]"#.utf8)
                : Data(#"[{"id":2,"title":"The Expanse","year":2015,"tvdbId":280619}]"#.utf8)
        } else {
            data = Data("[]".utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func postCount(_ kind: String) -> Int { posts[kind, default: 0] }
}

@Test func arrClientPreventsRepeatedMovieAndSeriesEnqueues() async throws {
    let fixture = ArrDuplicateFixture()
    let client = AppleArrClient { request in try await fixture.load(request) }

    for request in [
        (AppleArrKind.radarr, "https://radarr.example", "Arrival", 2016, "tmdb:329865", "/movies"),
        (.sonarr, "https://sonarr.example", "The Expanse", 2015, "tvdb:280619", "/series"),
    ] {
        let first = try await client.enqueueIfMissing(
            kind: request.0, baseURL: request.1, apiKey: "key", title: request.2,
            year: request.3, mediaID: request.4, rootFolderPath: request.5, qualityProfileID: "7"
        )
        let second = try await client.enqueueIfMissing(
            kind: request.0, baseURL: request.1, apiKey: "key", title: request.2,
            year: request.3, mediaID: request.4, rootFolderPath: request.5, qualityProfileID: "7"
        )
        #expect(first == .enqueued)
        #expect(second == .alreadyPresent)
    }

    #expect(await fixture.postCount("radarr") == 1)
    #expect(await fixture.postCount("sonarr") == 1)
}

private actor ArrFallbackFixture {
    private var calls: [String] = []

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let host = request.url?.host ?? "missing"
        calls.append("\(host):\(request.httpMethod ?? "GET")")
        if host == "first.example" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let status = request.httpMethod == "POST" ? 201 : 200
        return (request.httpMethod == "POST" ? Data() : Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func recordedCalls() -> [String] { calls }
}

@Test func arrFallbackAttemptsCandidatesInOrderAndStopsAfterSuccess() async throws {
    let fixture = ArrFallbackFixture()
    let client = AppleArrClient { request in try await fixture.load(request) }
    let outcome = try await AppleArrFallbackPolicy.firstSuccessful([
        { try await client.enqueueIfMissing(kind: .radarr, baseURL: "https://first.example", apiKey: "key", title: "Arrival", year: 2016, mediaID: "tmdb:329865", rootFolderPath: "/movies", qualityProfileID: "7") },
        { try await client.enqueueIfMissing(kind: .radarr, baseURL: "https://second.example", apiKey: "key", title: "Arrival", year: 2016, mediaID: "tmdb:329865", rootFolderPath: "/movies", qualityProfileID: "7") },
        { Issue.record("Fallback must stop after the first success"); return AppleArrEnqueueOutcome.enqueued },
    ])

    #expect(outcome == .enqueued)
    #expect(await fixture.recordedCalls() == ["first.example:GET", "second.example:GET", "second.example:POST"])
}

private actor ArrCancellationFixture {
    private var shouldCancel = true
    private var posts = 0

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        if shouldCancel {
            shouldCancel = false
            throw CancellationError()
        }
        if request.httpMethod == "POST" { posts += 1 }
        return (
            request.httpMethod == "POST" ? Data() : Data("[]".utf8),
            HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 201 : 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func postCount() -> Int { posts }
}

@Test func arrCancellationDoesNotPoisonACompleteRetry() async throws {
    let fixture = ArrCancellationFixture()
    let client = AppleArrClient { request in try await fixture.load(request) }
    let enqueue: @Sendable () async throws -> AppleArrEnqueueOutcome = {
        try await client.enqueueIfMissing(
            kind: .radarr, baseURL: "https://radarr.example", apiKey: "key", title: "Arrival",
            year: 2016, mediaID: "tmdb:329865", rootFolderPath: "/movies", qualityProfileID: "7"
        )
    }

    await #expect(throws: CancellationError.self) { try await enqueue() }
    #expect(try await enqueue() == .enqueued)
    #expect(await fixture.postCount() == 1)
}
