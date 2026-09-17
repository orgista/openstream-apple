import Foundation
import Testing
@testable import OpenStreamApple

@Test func directPlaybackInputAcceptsHTTPAndRejectsInvalidOrCredentialBearingLocators() {
    #expect(AppleDirectPlaybackInput.url(" http://127.0.0.1:8765/media/movie.mp4 ") != nil)
    #expect(AppleDirectPlaybackInput.url("https://media.example/a.mkv?token=opaque") != nil)
    for value in ["", "file:///private/movie.mp4", "smb://server/movie.mp4", "https:///", "https://user:password@media.example/movie.mp4", "https://media.example/a b.mp4"] {
        #expect(AppleDirectPlaybackInput.url(value) == nil)
    }
}
