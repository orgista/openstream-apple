import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleStreamServiceKey that exercise domain extraction
/// and add-on name handling beyond the basic happy-path in
/// AppleStreamServiceHealthTests.
struct AppleStreamServiceKeyEdgeTests {

    // ----------------------------------------------------------------
    // domain(of:) — co.jp with different company labels

    @Test
    func differentCoJpCompaniesProduceDifferentKeys() throws {
        let urlA = try #require(URL(string: "http://a.one.co.jp/stream.m3u8"))
        let urlB = try #require(URL(string: "http://b.two.co.jp/stream.m3u8"))

        let keyA = try #require(AppleStreamServiceKey.key(addonName: nil, url: urlA))
        let keyB = try #require(AppleStreamServiceKey.key(addonName: nil, url: urlB))

        #expect(keyA == "|one.co.jp")
        #expect(keyB == "|two.co.jp")
        #expect(keyA != keyB)
    }

    // ----------------------------------------------------------------
    // domain(of:) — plain .com subdomains group to same key

    @Test
    func plainComSubdomainsGroupToSameKey() throws {
        let urlA = try #require(URL(string: "http://cdn.fixture.example/stream.m3u8"))
        let urlB = try #require(URL(string: "http://media.fixture.example/stream.m3u8"))

        let keyA = try #require(AppleStreamServiceKey.key(addonName: nil, url: urlA))
        let keyB = try #require(AppleStreamServiceKey.key(addonName: nil, url: urlB))

        #expect(keyA == keyB)
        #expect(keyA == "|fixture.example")
    }

    // ----------------------------------------------------------------
    // domain(of:) — IPv4 host kept whole

    @Test
    func ipv4HostKeptWhole() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8080/stream.m3u8"))
        let key = try #require(AppleStreamServiceKey.key(addonName: nil, url: url))

        // url.host() strips the port, leaving "127.0.0.1"
        #expect(key == "|127.0.0.1")
    }

    // ----------------------------------------------------------------
    // domain(of:) — host with port in URL

    @Test
    func hostWithPortStripsPort() throws {
        let url = try #require(URL(string: "http://media.fixture.example:8443/stream.m3u8"))
        let key = try #require(AppleStreamServiceKey.key(addonName: nil, url: url))

        #expect(key == "|fixture.example")
    }

    // ----------------------------------------------------------------
    // key() — uppercase host is lowercased

    @Test
    func uppercaseHostIsLowercased() throws {
        let url = try #require(URL(string: "http://CDN.FIXTURE.EXAMPLE/stream.m3u8"))
        let key = try #require(AppleStreamServiceKey.key(addonName: nil, url: url))

        #expect(key == "|fixture.example")
    }

    // ----------------------------------------------------------------
    // key() — nil and empty add-on names produce same key

    @Test
    func nilAndEmptyAddonNameProduceSameKey() throws {
        let url = try #require(URL(string: "http://a.fixture.example/stream.m3u8"))

        let keyNil = try #require(AppleStreamServiceKey.key(addonName: nil, url: url))
        let keyEmpty = try #require(AppleStreamServiceKey.key(addonName: "", url: url))

        #expect(keyNil == keyEmpty)
        #expect(keyNil == "|fixture.example")
    }

    // ----------------------------------------------------------------
    // key() — add-on name with surrounding spaces and mixed case

    @Test
    func addonNameTrimsWhitespaceAndLowercases() throws {
        let url = try #require(URL(string: "http://a.fixture.example/stream.m3u8"))

        let key = try #require(AppleStreamServiceKey.key(addonName: "  My Add-On  ", url: url))

        #expect(key == "my add-on|fixture.example")
    }

    // ----------------------------------------------------------------
    // key() — same host but different add-ons yield different keys

    @Test
    func sameHostDifferentAddonsYieldDifferentKeys() throws {
        let url = try #require(URL(string: "http://a.fixture.example/stream.m3u8"))

        let keyA = try #require(AppleStreamServiceKey.key(addonName: "Alpha", url: url))
        let keyB = try #require(AppleStreamServiceKey.key(addonName: "Beta", url: url))

        #expect(keyA != keyB)
        #expect(keyA == "alpha|fixture.example")
        #expect(keyB == "beta|fixture.example")
    }
}
