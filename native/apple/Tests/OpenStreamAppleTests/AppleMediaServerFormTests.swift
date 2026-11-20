import Testing
import Foundation
@testable import OpenStreamApple

@Suite struct AppleMediaServerFormTests {
    @Test("Policy: URL Normalization")
    func testNormalizedBaseURL() {
        #expect(AppleMediaServerFormPolicy.normalizedBaseURL("jellyfin.local:8096")?.absoluteString == "http://jellyfin.local:8096")
        #expect(AppleMediaServerFormPolicy.normalizedBaseURL(" https://fixture.example/jellyfin/ ")?.absoluteString == "https://fixture.example/jellyfin/")
        #expect(AppleMediaServerFormPolicy.normalizedBaseURL("not a url with space") == nil)
        #expect(AppleMediaServerFormPolicy.normalizedBaseURL("") == nil)
        #expect(AppleMediaServerFormPolicy.normalizedBaseURL("http://") == nil) // no host
    }
    
    @Test("Policy: Can Test")
    func testCanTest() {
        #expect(AppleMediaServerFormPolicy.canTest(urlText: "jellyfin.local:8096") == true)
        #expect(AppleMediaServerFormPolicy.canTest(urlText: " ") == false)
    }
    
    @Test("Policy: Can Save")
    func testCanSave() {
        #expect(AppleMediaServerFormPolicy.canSave(urlText: "jellyfin.local:8096", username: "user") == true)
        #expect(AppleMediaServerFormPolicy.canSave(urlText: "jellyfin.local:8096", username: "   ") == false)
        #expect(AppleMediaServerFormPolicy.canSave(urlText: "invalid url", username: "user") == false)
    }
    
    @Test("Policy: Can Sign In")
    func testCanSignIn() {
        #expect(AppleMediaServerFormPolicy.canSignIn(email: "a@b.com", password: "p") == true)
        #expect(AppleMediaServerFormPolicy.canSignIn(email: "ab.com", password: "p") == false)
        #expect(AppleMediaServerFormPolicy.canSignIn(email: "a@b.com", password: "") == false)
        #expect(AppleMediaServerFormPolicy.canSignIn(email: " ", password: "p") == false)
    }
    
    @Test("Policy: Default Name")
    func testDefaultName() {
        let info = AppleMediaServerPublicInfo(serverName: "ServerName", version: nil, id: nil, productName: nil)
        #expect(AppleMediaServerFormPolicy.defaultName(kind: .jellyfin, typedName: "My Server", publicInfo: info, host: "host") == "My Server")
        #expect(AppleMediaServerFormPolicy.defaultName(kind: .jellyfin, typedName: "  ", publicInfo: info, host: "host") == "ServerName")
        #expect(AppleMediaServerFormPolicy.defaultName(kind: .jellyfin, typedName: "", publicInfo: nil, host: "host") == "host")
        #expect(AppleMediaServerFormPolicy.defaultName(kind: .emby, typedName: "", publicInfo: nil, host: nil) == "Emby")
    }
    
    @Test("Policy: Error Messages")
    func testErrorMessages() {
        #expect(AppleMediaServerFormPolicy.message(for: .invalidCredentials) == "Wrong username or password.")
        #expect(AppleMediaServerFormPolicy.message(for: .server(status: 500)) == "The server answered with an error (500).")
        #expect(AppleMediaServerFormPolicy.message(for: .malformedResponse) == "The server's reply made no sense.")
        #expect(AppleMediaServerFormPolicy.message(for: .unreachable) == "Can't reach the server.")
        #expect(AppleMediaServerFormPolicy.message(for: .unsupported) == "Not supported by this server.")
        
        let allMessages = [
            AppleMediaServerFormPolicy.message(for: .invalidCredentials),
            AppleMediaServerFormPolicy.message(for: .server(status: 500)),
            AppleMediaServerFormPolicy.message(for: .malformedResponse),
            AppleMediaServerFormPolicy.message(for: .unreachable),
            AppleMediaServerFormPolicy.message(for: .unsupported)
        ]
        for msg in allMessages {
            #expect(!msg.lowercased().contains("http"))
        }
    }
}
