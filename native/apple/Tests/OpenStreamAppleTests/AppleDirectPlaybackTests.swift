import Foundation
import Testing
@testable import OpenStreamApple

@Test @MainActor func directPlaybackResumesSavedMediaAndRestartsCompletedMedia() throws {
    let domain = "direct-playback-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = ApplePlaybackStore(defaults: defaults)
    let url = try #require(URL(string: "https://fixture.example/movie.mp4"))
    let identity = ApplePlaybackIdentity.digest(for: url.absoluteString)
    store.save(mediaID: identity, position: 450, duration: 1800)
    #expect(AppleDirectPlaybackInput.request(for: url, store: store).resumePosition == 450)
    store.save(mediaID: identity, position: 1799, duration: 1800)
    #expect(AppleDirectPlaybackInput.request(for: url, store: store).resumePosition == nil)
}

@Test func directPlaybackInputAcceptsHTTPAndRejectsInvalidOrCredentialBearingLocators() {
    #expect(AppleDirectPlaybackInput.url(" http://127.0.0.1:8765/media/movie.mp4 ") != nil)
    #expect(AppleDirectPlaybackInput.url("https://media.example/a.mkv?token=opaque") != nil)
    for value in ["", "file:///private/movie.mp4", "smb://server/movie.mp4", "https:///", "https://user:password@media.example/movie.mp4", "https://media.example/a b.mp4"] {
        #expect(AppleDirectPlaybackInput.url(value) == nil)
    }
}
