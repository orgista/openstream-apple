import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleMediaServerDownloadTests {
    private func session(_ kind: AppleMediaServerKind) -> AppleMediaServerSession {
        .init(kind: kind, baseURL: URL(string: "https://fixture.example/stable")!, accessToken: "fixture-token", userID: "user")
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby])
    func downloadPreservesPathBaseAndUsesHeaderAuthentication(kind: AppleMediaServerKind) throws {
        let request = try AppleMediaServerClient(deviceID: "fixture").downloadRequest(session: session(kind), itemID: "movie", allowed: true)
        #expect(request.url?.path == "/stable/Items/movie/Download")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
        #expect(request.httpMethod == "GET")
    }

    @Test func deniedDownloadBuildsNoRequest() {
        #expect(throws: AppleMediaServerError.downloadNotAllowed) {
            try AppleMediaServerClient(deviceID: "fixture").downloadRequest(session: session(.jellyfin), itemID: "movie", allowed: false)
        }
    }

    @Test(arguments: [true, false])
    func checksCurrentUserPolicy(allowed: Bool) async throws {
        let client = AppleMediaServerClient(loader: { request in
            #expect(request.url?.path == "/stable/" + "Users/user")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
            return (Data("{\"Policy\":{\"EnableContentDownloading\":\(allowed)}}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        #expect(try await client.downloadsAllowed(session: session(.jellyfin)) == allowed)
    }

    @Test func missingPolicyFailsClosed() async throws {
        let client = AppleMediaServerClient(loader: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        #expect(try await client.downloadsAllowed(session: session(.emby)) == false)
    }

    @Test func plexDownloadsOriginalWithServerEnforcedFlag() throws {
        let client = ApplePlexClient(clientIdentifier: "fixture")
        let part = ApplePlexItem.Part(key: "/library/parts/12/file.mkv", container: "mkv", file: nil)
        let request = try client.downloadRequest(session: session(.plex), part: part, allowed: true)
        #expect(request.url?.path == "/stable/library/parts/12/file.mkv")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "download", value: "1")])
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "fixture-token")
        #expect(throws: AppleMediaServerError.downloadNotAllowed) {
            try client.downloadRequest(session: session(.plex), part: part, allowed: false)
        }
    }

    @Test(arguments: [true, false])
    func plexChecksServerPermission(allowed: Bool) async throws {
        let client = ApplePlexClient(loader: { request in
            (Data("{\"MediaContainer\":{\"allowSync\":\(allowed ? 1 : 0)}}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "fixture")
        #expect(try await client.downloadsAllowed(session: session(.plex)) == allowed)
    }
    @Test @MainActor func cancellingSeasonCancelsItsBackgroundJobsOnce() async {
        let queue = AppleSeasonDownloadQueue()
        var cancellations = 0
        queue.start(episodeIDs: ["opaque-episode-a", "opaque-episode-b"], onCancel: { cancellations += 1 }) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        queue.cancel()
        queue.cancel()
        await queue.waitUntilFinished()
        #expect(cancellations == 1)
        #expect(queue.completed == 0)
    }

    @Test func serverOnlyLibraryIsVisibleInDiscover() {
        #expect(AppleCatalogShelfPolicy.hasDiscoverContent(hasLocalLibrary: false, hasMediaServerItems: true))
        #expect(!AppleCatalogShelfPolicy.hasDiscoverContent(hasLocalLibrary: false, hasMediaServerItems: false))
        // Top 10 rows alone are something to show, not "Nothing to Show".
        #expect(AppleCatalogShelfPolicy.hasDiscoverContent(hasLocalLibrary: false, hasMediaServerItems: false, hasTop10: true))
    }

    @Test func offlineRequestUsesOnlySavedFileAndNoServerCredentials() throws {
        let record = AppleOfflineRecord(mediaID: "ms:fixture:opaque-episode", localURL: URL(fileURLWithPath: "/tmp/fixture.media"), sourceExtension: "media", container: "mp4")
        let request = try AppleMediaServerLibraryStore.offlinePlaybackRequest(record: record, title: "Fixture", resumePosition: 12)
        #expect(request.url == record.localURL)
        #expect(request.headers.isEmpty)
        #expect(request.hints.libraryFileURL == record.localURL)
        #expect(request.mediaID == record.mediaID)
        #expect(request.resumePosition == 12)
        let invalid = AppleOfflineRecord(mediaID: record.mediaID, localURL: URL(string: "https://fixture.example/video")!, sourceExtension: "mp4")
        #expect(throws: AppleOfflineStoreError.uncontainedSourceFileURL) {
            try AppleMediaServerLibraryStore.offlinePlaybackRequest(record: invalid, title: "Fixture", resumePosition: nil)
        }
    }

    @Test func pausedBackgroundJobSurvivesRelaunch() throws {
        let job = AppleMediaServerBackgroundDownloads.Job(id: UUID(), mediaID: "fixture-episode", title: "Fixture", subtitle: nil, artworkURL: nil, isPaused: true)
        let data = try JSONEncoder().encode(job)
        let restored = try JSONDecoder().decode(AppleMediaServerBackgroundDownloads.Job.self, from: data)
        #expect(restored.isPaused)
        #expect(restored.id == job.id)
        #expect(restored.mediaID == job.mediaID)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isPaused")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(AppleMediaServerBackgroundDownloads.Job.self, from: legacyData).isPaused == false)
    }

}
