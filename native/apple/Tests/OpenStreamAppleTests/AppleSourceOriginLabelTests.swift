import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15: wanted Stremio-hosted add-ons easier to tell apart. The
/// icon route was not available (no fetchable favicon) and a shared mark would
/// have made them harder to tell apart, not easier — so the row names the
/// origin instead.
@Suite("Source origin label")
struct AppleSourceOriginLabelTests {
    private typealias L = AppleSourceOriginLabel
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func officialAddOnsCollapseToTheirSharedOrigin() {
        #expect(L.origin(for: url("https://v3-cinemeta.strem.io/manifest.json")) == "strem.io")
        #expect(L.origin(for: url("https://opensubtitles-v3.strem.io/manifest.json")) == "strem.io")
    }

    @Test func aSelfHostedAddOnKeepsItsOwnName() {
        #expect(L.origin(for: url("https://addons.example.com/manifest.json")) == "example.com")
        #expect(L.origin(for: url("https://example.com/manifest.json")) == "example.com")
    }

    @Test func countryDomainsKeepEnoughToBeMeaningful() {
        #expect(L.origin(for: url("https://addon.example.co.uk/manifest.json")) == "example.co.uk")
    }

    @Test func anAddressIsLeftWhole() {
        #expect(L.origin(for: url("http://192.168.1.50:8080/manifest.json")) == "192.168.1.50")
    }

    @Test func nothingIsInventedWhenThereIsNoHost() {
        #expect(L.origin(for: nil) == nil)
        #expect(L.subtitle(kind: "Add-on", url: nil) == "Add-on")
    }

    @Test func theSubtitleReadsAsOneLine() {
        #expect(L.subtitle(kind: "Add-on", url: url("https://v3-cinemeta.strem.io/manifest.json"))
                == "Add-on · strem.io")
    }
}
