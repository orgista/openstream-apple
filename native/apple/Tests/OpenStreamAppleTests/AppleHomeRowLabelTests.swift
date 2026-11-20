import Testing
@testable import OpenStreamApple

struct AppleHomeRowLabelTests {
    @Test(arguments: ["Featured · The Movie Database", "Featured - Rill", "Featured | Server", "Featured (Collection)"])
    func suffixesAreRemoved(name: String) {
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["movie"]) == "Featured Movies")
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["series"]) == "Featured Shows")
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["movie", "series"]) == "Featured")
    }

    @Test(arguments: [" · Popular", " - Popular", " | Popular", "(Collection) Popular"])
    func firstNonemptyPartWins(name: String) {
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["movie"]) == "Popular Movies")
    }

    @Test(arguments: ["Popular Movies", "Movie Night", "Film Favorites"])
    func movieWordsAreNotDoubled(name: String) {
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["movie"]) == name)
    }

    @Test(arguments: ["Popular Shows", "Show Time", "Series", "TV Favorites"])
    func showWordsAreNotDoubled(name: String) {
        #expect(AppleHomeRowLabel.clean(name: name, mediaTypes: ["series"]) == name)
    }

    @Test func matchingUsesWholeWordsAndMixedRowsKeepTheirName() {
        #expect(AppleHomeRowLabel.clean(name: "Showcase", mediaTypes: ["series"]) == "Showcase Shows")
        #expect(AppleHomeRowLabel.clean(name: "Kids (Family)", mediaTypes: ["movie", "series"]) == "Kids")
        #expect(AppleHomeRowLabel.clean(name: "  ", mediaTypes: ["movie"]).isEmpty)
    }
}
