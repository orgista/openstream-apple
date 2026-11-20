import Foundation
import Testing
@testable import OpenStreamApple

struct AppleMediaServerDiscoveryTests {
    @Test func decodesServerAndKeepsBasePath() throws {
        let data = Data(#"{"Id":"server-1","Name":"Living Room","Address":"https://fixture.example/jellyfin"}"#.utf8)
        let server = try #require(AppleDiscoveredMediaServer.decode(data))
        #expect(server.name == "Living Room")
        #expect(server.baseURL.path == "/jellyfin")
    }

    @Test(arguments: [
        #"{"Id":"a","Name":"Test","Address":"file:///tmp/server"}"#,
        #"{"Id":"a","Name":"Test","Address":"https://user:password@fixture.example"}"#,
        #"{"Id":"a","Name":"Test","Address":"https://fixture.example/?token=secret"}"#,
        #"{"Name":"Test"}"#,
        "not json"
    ]) func rejectsInvalidAnnouncements(_ json: String) {
        #expect(AppleDiscoveredMediaServer.decode(Data(json.utf8)) == nil)
    }

    @Test func prefersQuickConnectOnlyWhenSupported() {
        #expect(AppleMediaServerFormPolicy.prefersQuickConnect(isTV: true, kind: .jellyfin, enabled: true))
        #expect(AppleMediaServerFormPolicy.prefersQuickConnect(isTV: true, kind: .emby, enabled: true) == false)
        #expect(AppleMediaServerFormPolicy.prefersQuickConnect(isTV: true, kind: .jellyfin, enabled: false) == false)
        #expect(AppleMediaServerFormPolicy.prefersQuickConnect(isTV: false, kind: .jellyfin, enabled: true) == false)
    }
}
