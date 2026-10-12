#if DEBUG
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Dev sources file")
struct AppleDevSourcesPolicyTests {
    private func decode(_ json: String) throws -> AppleDevSourcesFile {
        try AppleDevSourcesPolicy.decode(Data(json.utf8))
    }

    @Test func folderKindAddsALibraryFolderByPath() throws {
        let file = try decode("""
        {"version": 1, "sources": [
          {"kind": "folder", "name": "Disc Fixture", "path": "/tmp/disc-fixture"},
          {"kind": "folder", "name": "No Path"}
        ]}
        """)
        #expect(file.sources == [.folder(name: "Disc Fixture", path: "/tmp/disc-fixture")])
        #expect(file.problems == ["folder No Path: missing path"])
        let saved = AppleSource(kind: .library, name: "Disc Fixture", url: URL(fileURLWithPath: "/tmp/disc-fixture"))
        #expect(AppleDevSourcesPolicy.alreadyAdded(.folder(name: "x", path: "/tmp/disc-fixture"), in: [saved]))
        #expect(AppleDevSource.folder(name: "x", path: "/tmp/a").secrets.isEmpty)
    }

    @Test func schemaV1DecodesEveryKindAndTheServiceKeys() throws {
        let file = try decode("""
        {"version": 1, "sources": [
          {"kind": "stremio", "name": "Cinemeta", "manifestURL": "https://addon.fixture.example/manifest.json"},
          {"kind": "xtream", "name": "Box", "serverURL": "http://iptv.fixture.example:8080",
           "username": "fixture-user", "password": "fixture-password", "epgURL": ""},
          {"kind": "m3u", "name": "List", "playlistURL": "https://iptv.fixture.example/list.m3u",
           "epgURL": "https://iptv.fixture.example/epg.xml"},
          {"kind": "smb", "name": "NAS", "host": "192.0.2.10", "port": "1445", "share": "Media",
           "path": "", "username": "fixture-user", "password": "fixture-password", "domain": ""},
          {"kind": "mediaServer", "server": "Jellyfin", "name": "Jelly", "url": "http://media.fixture.example:8096",
           "username": "fixture-user", "password": "fixture-password"},
          {"kind": "mediaServer", "server": "plex", "name": "Plex", "url": "http://plex.fixture.example:32400",
           "token": "fixture-token"}
        ], "settings": {"tmdbAPIKey": "fixture-tmdb",
          "radarr": {"url": "http://radarr.fixture.example", "apiKey": "fixture-radarr",
                     "rootFolderPath": "/movies", "qualityProfileID": 4},
          "sonarr": {"url": "", "apiKey": ""}, "traktClientID": "fixture-trakt"}}
        """)

        #expect(file.problems.isEmpty)
        #expect(file.ignoredKinds.isEmpty)
        #expect(file.sources == [
            .stremio(name: "Cinemeta", manifestURL: "https://addon.fixture.example/manifest.json"),
            .xtream(name: "Box", serverURL: "http://iptv.fixture.example:8080", username: "fixture-user",
                    password: "fixture-password", epgURL: nil),
            .m3u(name: "List", playlistURL: "https://iptv.fixture.example/list.m3u",
                 epgURL: "https://iptv.fixture.example/epg.xml"),
            .smb(name: "NAS", host: "192.0.2.10", port: 1445, share: "Media", path: "",
                 username: "fixture-user", password: "fixture-password", domain: ""),
            .mediaServer(kind: .jellyfin, name: "Jelly", url: "http://media.fixture.example:8096",
                         credential: .password(username: "fixture-user", password: "fixture-password")),
            .mediaServer(kind: .plex, name: "Plex", url: "http://plex.fixture.example:32400",
                         credential: .token("fixture-token")),
        ])
        #expect(file.settings.tmdbAPIKey == "fixture-tmdb")
        #expect(file.settings.radarr?.qualityProfileID == "4")
        #expect(file.settings.sonarr == nil)
        #expect(file.settings.appliedNames == ["tmdb", "radarr", "trakt"])
    }

    @Test func unknownKindsAreIgnoredAndTheRestStillImports() throws {
        let file = try decode("""
        {"version": 1, "sources": [
          {"kind": "torrent", "name": "Later"},
          {"kind": "stremio", "manifestURL": "https://addon.fixture.example/manifest.json"}
        ]}
        """)

        #expect(file.ignoredKinds == ["torrent"])
        #expect(file.sources.count == 1)
        #expect(file.problems.isEmpty)
        #expect(file.settings == AppleDevSettings())
    }

    @Test func missingFieldsAreReportedByNameNeverByValue() throws {
        let file = try decode("""
        {"version": 1, "sources": [
          {"kind": "xtream", "name": "Box", "serverURL": "http://iptv.fixture.example", "username": "fixture-user"},
          {"kind": "mediaServer", "server": "plex", "name": "Plex", "url": "http://plex.fixture.example"},
          {"kind": "mediaServer", "server": "kodi", "url": "http://kodi.fixture.example"},
          {"kind": "smb", "host": "192.0.2.10"},
          {"name": "No kind"}
        ]}
        """)

        #expect(file.sources.isEmpty)
        #expect(file.problems == [
            "xtream Box: missing password",
            "mediaServer Plex: missing token",
            "mediaServer source 3: missing server",
            "smb source 4: missing share",
            "source 5: missing kind",
        ])
        #expect(!file.problems.joined().contains("fixture-user"))
    }

    @Test func onlySchemaVersionOneIsRead() {
        #expect(throws: AppleDevSourcesPolicy.DecodeError.unsupportedVersion(2)) {
            try decode(#"{"version": 2, "sources": []}"#)
        }
        #expect(throws: AppleDevSourcesPolicy.DecodeError.unsupportedVersion(nil)) {
            try decode(#"{"sources": []}"#)
        }
        #expect(throws: AppleDevSourcesPolicy.DecodeError.notJSON) {
            try decode("not json")
        }
    }

    @Test func aSourceWithTheSameKindAndAddressIsAlreadyAdded() throws {
        let addon = try #require(URL(string: "https://addon.fixture.example/manifest.json"))
        let share = try AppleSMBEndpointPolicy.makeURL(host: "192.0.2.10", port: 445, share: "Media")
        let saved = [
            AppleSource(kind: .stremio, name: "Cinemeta", url: addon),
            AppleSource(kind: .nas, name: "NAS", url: share),
            AppleSource(kind: .liveTV, name: "List", url: try #require(URL(string: "https://iptv.fixture.example/list.m3u")),
                        iptvType: .m3u),
        ]

        #expect(AppleDevSourcesPolicy.alreadyAdded(
            .stremio(name: "", manifestURL: "https://addon.fixture.example/manifest.json"), in: saved))
        #expect(!AppleDevSourcesPolicy.alreadyAdded(
            .stremio(name: "", manifestURL: "https://other.fixture.example/manifest.json"), in: saved))
        #expect(AppleDevSourcesPolicy.alreadyAdded(
            .smb(name: "Renamed", host: "192.0.2.10", port: 445, share: "Media", path: "",
                 username: "", password: "", domain: ""), in: saved))
        #expect(AppleDevSourcesPolicy.alreadyAdded(
            .m3u(name: "", playlistURL: "https://iptv.fixture.example/list.m3u", epgURL: nil), in: saved))
        // Same address, different kind: a playlist is not an Xtream login.
        #expect(!AppleDevSourcesPolicy.alreadyAdded(
            .xtream(name: "", serverURL: "https://iptv.fixture.example/list.m3u", username: "u",
                    password: "p", epgURL: nil), in: saved))
    }

    @Test func traceLinesCarryNoSecrets() {
        struct Failure: LocalizedError {
            var errorDescription: String? {
                "login fixture-password refused at http://iptv.fixture.example:8080/player_api.php?username=fixture-user"
            }
        }
        let source = AppleDevSource.xtream(name: "Box", serverURL: "http://iptv.fixture.example:8080",
                                           username: "fixture-user", password: "fixture-password", epgURL: nil)

        let reason = AppleDevSourcesPolicy.failureReason(Failure(), hiding: source.secrets)
        let line = AppleDevSourcesPolicy.traceLine(for: source, outcome: .failed(reason))

        #expect(line.hasPrefix("dev sources: xtream Box: failed login"))
        #expect(!line.contains("fixture-password"))
        #expect(!line.contains("fixture-user"))
        #expect(!line.contains("iptv.fixture.example"))
        #expect(AppleDevSourcesPolicy.traceLine(
            for: .stremio(name: "", manifestURL: "https://addon.fixture.example/secret-config/manifest.json"),
            outcome: .added) == "dev sources: stremio addon.fixture.example: added")
        #expect(AppleDevSourcesPolicy.summaryLine(added: 2, exists: 1, failed: 0, skipped: 3)
            == "dev sources: done (2 added, 1 exists, 0 failed, 3 skipped)")
    }
}
#endif
