import Foundation
import Testing
@testable import OpenStreamApple

/// Owner-visible bug: the *9/11: One Day in America* hero and title page both
/// read "the 9/11 Memorial &amp; Museum", because Cinemeta hands back an
/// overview that was escaped for a web page upstream and nothing decoded it.
@Suite("HTML entities in catalogue text")
struct AppleHTMLEntitiesTests {
    @Test func theAmpersandTheOwnerActuallySawIsDecoded() {
        #expect(AppleHTMLEntities.decoded("the 9/11 Memorial &amp; Museum")
            == "the 9/11 Memorial & Museum")
    }

    @Test func alreadyEscapedMarkupSurvivesTheDecode() {
        // &amp;lt; must not collapse to "<": decoding the ampersand first
        // would re-introduce markup the source deliberately escaped.
        #expect(AppleHTMLEntities.decoded("&amp;lt;b&amp;gt;") == "&lt;b&gt;")
    }

    @Test func realMarkupIsStillDecodedToItsCharacter() {
        #expect(AppleHTMLEntities.decoded("&lt;b&gt;") == "<b>")
    }

    @Test func quotesAndDashesCarriedByOverviewsAreDecoded() {
        #expect(AppleHTMLEntities.decoded("It&#39;s &quot;fine&quot; &mdash; really&hellip;")
            == "It's \"fine\" — really…")
    }

    @Test func textWithoutAnAmpersandIsReturnedUnchanged() {
        let plain = "A documentary about the morning of September 11, 2001."
        #expect(AppleHTMLEntities.decoded(plain) == plain)
    }

    @Test func nilStaysNil() {
        #expect(AppleHTMLEntities.decoded(String?.none) == nil)
    }

    @Test func aStremioOverviewIsDecodedOnTheWayIn() {
        let value = AppleStremioEpisode(
            id: "tt14734548:1:1", title: "First Response",
            overview: "In collaboration with the 9/11 Memorial &amp; Museum.")
        #expect(value.overview == "In collaboration with the 9/11 Memorial & Museum.")
    }

    @Test func aStremioTitleIsDecodedOnTheWayIn() {
        let value = AppleStremioEpisode(id: "x", title: "Law &amp; Order")
        #expect(value.title == "Law & Order")
    }
}

/// The bug the owner could see: this is the payload shape Cinemeta actually
/// returns for *9/11: One Day in America*, and the escaped ampersand reached
/// the hero and the title page verbatim.
@Test func aCinemetaDescriptionIsDecodedWhenTheCatalogIsParsed() async throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Cinemeta",
        url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
        resources: ["catalog"],
        catalogs: [AppleStremioCatalog(type: "series", id: "top")]
    )
    let client = AppleStremioCatalogClient { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"""
        {"metas":[{"imdb_id":"tt14734548","type":"series","name":"Law &amp; Order",
          "description":"In official collaboration with the 9/11 Memorial &amp; Museum."}]}
        """#.utf8)
        return (data, response)
    }

    let items = try await client.load(source: source, catalog: source.catalogs[0])

    #expect(items.first?.name == "Law & Order")
    #expect(items.first?.summary == "In official collaboration with the 9/11 Memorial & Museum.")
}

/// A fresh install still showed the escaped ampersand, because the catalogue
/// is cached on disk and the synthesised `Decodable` assigned the stored
/// properties directly — skipping the initialiser that normalises them.
@Test func aCachedCatalogItemIsNormalisedWhenItIsReadBack() throws {
    let escaped = #"""
    {"id":"series:tt14734548","mediaID":"tt14734548","type":"series",
     "name":"Law &amp; Order",
     "summary":"In official collaboration with the 9/11 Memorial &amp; Museum."}
    """#
    let item = try JSONDecoder().decode(AppleCatalogItem.self, from: Data(escaped.utf8))

    #expect(item.name == "Law & Order")
    #expect(item.summary == "In official collaboration with the 9/11 Memorial & Museum.")
    #expect(item.id == "series:tt14734548")
}

/// Round-tripping must not change the text a second time.
@Test func encodingAndDecodingATitleTwiceIsStable() throws {
    let original = AppleCatalogItem(
        mediaID: "tt1", type: "movie", name: "Law &amp; Order",
        summary: "Memorial &amp; Museum")
    let once = try JSONDecoder().decode(
        AppleCatalogItem.self, from: try JSONEncoder().encode(original))
    let twice = try JSONDecoder().decode(
        AppleCatalogItem.self, from: try JSONEncoder().encode(once))

    #expect(once.name == "Law & Order")
    #expect(twice.name == "Law & Order")
    #expect(twice.summary == "Memorial & Museum")
}
