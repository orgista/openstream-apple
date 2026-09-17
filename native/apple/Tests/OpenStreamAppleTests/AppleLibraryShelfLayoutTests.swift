import Testing
@testable import OpenStreamApple

/// B12: the sort control is meant to sit on the first shelf header only. The
/// old rule keyed it to the first *source*, which loses the control entirely
/// whenever that source draws nothing — one offline NAS ahead of a working one
/// is enough, and then no shelf carries the sort menu at all.
@Suite("Library sort accessory placement")
struct AppleLibraryShelfLayoutTests {
    @Test func theAccessoryGoesOnTheFirstShelfOfTheFirstSourceThatDrawsOne() {
        let pick = AppleLibraryShelfLayout.accessoryShelf(
            sourcesWithKinds: [["movie", "show"], ["movie"]])
        #expect(pick?.sourceIndex == 0)
        #expect(pick?.kind == "movie")
    }

    /// The bug: an empty first source used to leave every shelf without it.
    @Test func anEmptyFirstSourceHandsTheAccessoryToTheNextOne() {
        let pick = AppleLibraryShelfLayout.accessoryShelf(
            sourcesWithKinds: [[], ["show", "other"]])
        #expect(pick?.sourceIndex == 1)
        #expect(pick?.kind == "show")
    }

    @Test func severalEmptySourcesInARowAreSkipped() {
        let pick = AppleLibraryShelfLayout.accessoryShelf(
            sourcesWithKinds: [[], [], [], ["other"]])
        #expect(pick?.sourceIndex == 3)
        #expect(pick?.kind == "other")
    }

    /// A source that draws only shows must put it on Shows, not on a Movies
    /// shelf that does not exist.
    @Test func theKindIsTheFirstOneThatSourceActuallyDraws() {
        let pick = AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: [["show"]])
        #expect(pick?.kind == "show")
    }

    @Test func nothingDrawnMeansNoAccessory() {
        #expect(AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: []) == nil)
        #expect(AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: [[], []]) == nil)
    }

    /// Exactly one shelf may carry it, whatever the shape of the library.
    @Test func exactlyOneShelfEverCarriesIt() {
        let shapes: [[[String]]] = [
            [["movie", "show", "other"]],
            [[], ["movie"], ["show"]],
            [["movie"], ["movie"], ["movie"]],
        ]
        for shape in shapes {
            let pick = AppleLibraryShelfLayout.accessoryShelf(sourcesWithKinds: shape)
            let matches = shape.enumerated().flatMap { index, kinds in
                kinds.map { (index, $0) }
            }.filter { $0.0 == pick?.sourceIndex && $0.1 == pick?.kind }
            #expect(matches.count == 1, "shape \(shape) matched \(matches.count) shelves")
        }
    }
}
