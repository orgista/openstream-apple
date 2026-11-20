import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Semantic title actions and TV resume captions")
struct AppleSemanticActionTests {
    @Test func ratingsKeepDistinctSelectedAndUnselectedStates() {
        #expect(AppleSemanticAction.rating(.doubleUp, selected: true).symbol == "heart.fill")
        #expect(AppleSemanticAction.rating(.doubleUp, selected: false).symbol == "heart")
        #expect(AppleTitleRating.doubleUp.systemImage == "heart.fill")
        #expect(AppleSemanticAction.rating(.down, selected: false).symbol == "hand.thumbsdown")
        #expect(AppleSemanticAction.myList(saved: true).label == "Remove from My List")
        #expect(AppleSemanticAction.myList(saved: false).symbol == "plus")
        #expect(AppleSemanticAction.download(.completed).symbol == "arrow.down.circle.fill")
    }

    @Test func tvResumeCaptionsUseOnlyKnownUnfinishedProgress() {
        #expect(AppleContinueWatchingCaption.tvLine(type: "series", partID: "tt1234567:2:5", position: 120, duration: 2400) == "S2 E5 · 38 min left")
        #expect(AppleContinueWatchingCaption.tvLine(type: "series", partID: nil, position: 120, duration: 2400) == "38 min left")
        #expect(AppleContinueWatchingCaption.tvLine(type: "movie", partID: nil, position: 120, duration: 2400) == "38 min left")
        #expect(AppleContinueWatchingCaption.tvLine(type: "movie", partID: nil, position: 0, duration: 0) == nil)
        #expect(AppleContinueWatchingCaption.tvLine(type: "movie", partID: nil, position: 90, duration: 100) == nil)
        #expect(AppleContinueWatchingCaption.tvLine(type: "movie", partID: nil, position: .nan, duration: 2400) == nil)
        #expect(AppleContinueWatchingCaption.tvLine(type: "series", partID: "tt1234567:2:5", position: 2399, duration: 2400) == nil)
    }
}
