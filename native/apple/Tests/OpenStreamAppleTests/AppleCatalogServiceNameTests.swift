import Testing
@testable import OpenStreamApple

@Suite("AppleCatalogServiceName")
struct AppleCatalogServiceNameTests {
    @Test("Matches known catalog IDs to service names")
    func matchesKnownCatalogs() {
        #expect(AppleCatalogServiceName.service(fromCatalogID: "nfx", name: nil) == "Netflix")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "amp", name: nil) == "Prime")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "hbm", name: nil) == "HBO Max")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "dnp", name: nil) == "Disney+")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "atp", name: nil) == "Apple TV+")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "pcp", name: nil) == "Peacock")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "pct", name: nil) == "Peacock")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "cru", name: nil) == "Crunchyroll")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "fmn", name: nil) == "Crunchyroll")
    }

    @Test("Matches Netflix Top 10 dynamic catalogs")
    func matchesNetflixTop10() {
        #expect(AppleCatalogServiceName.service(fromCatalogID: "netflix-top10-global", name: nil) == "Netflix")
        #expect(AppleCatalogServiceName.service(fromCatalogID: "netflix-top10-US", name: nil) == "Netflix")
    }

    @Test("Returns nil for unknown or generic catalogs")
    func returnsNilForUnknown() {
        #expect(AppleCatalogServiceName.service(fromCatalogID: "top", name: nil) == nil)
        #expect(AppleCatalogServiceName.service(fromCatalogID: "trending", name: nil) == nil)
        #expect(AppleCatalogServiceName.service(fromCatalogID: "cinemeta", name: nil) == nil)
    }
}
