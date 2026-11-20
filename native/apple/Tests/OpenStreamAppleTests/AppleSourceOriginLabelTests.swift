import Foundation
import Testing
@testable import OpenStreamApple

/// A source row names where the source lives in a few characters.
@Suite("Source origin label")
struct AppleSourceOriginLabelTests {
    private typealias L = AppleSourceOriginLabel
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func subdomainsCollapseToTheirOrigin() {
        #expect(L.origin(for: url("https://media.example.com/library")) == "example.com")
        #expect(L.origin(for: url("https://example.com/library")) == "example.com")
    }

    @Test func countryDomainsKeepEnoughToBeMeaningful() {
        #expect(L.origin(for: url("https://media.example.co.uk/list.m3u")) == "example.co.uk")
    }

    @Test func anAddressIsLeftWhole() {
        #expect(L.origin(for: url("http://192.168.1.50:8080/list.m3u")) == "192.168.1.50")
    }

    @Test func nothingIsInventedWhenThereIsNoHost() {
        #expect(L.origin(for: nil) == nil)
        #expect(L.subtitle(kind: "Media Server", url: nil) == "Media Server")
    }

    @Test func theSubtitleReadsAsOneLine() {
        #expect(L.subtitle(kind: "Media Server", url: url("https://media.example.com/library"))
                == "Media Server · example.com")
    }
}
