import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Apple TV live footer state")
struct AppleTVLiveFooterStateTests {
    @Test func freshPlayerStartsHiddenAndMenuDoesNotExit() {
        let state = AppleTVLiveFooterState()
        #expect(state.phase == .hidden)
        #expect(!state.isVisible)
        #expect(!state.menuExits)
    }

    @Test func menuShowsThenHidesThenExits() {
        var state = AppleTVLiveFooterState()
        #expect(state.apply(.menu) == .show)
        #expect(state.isVisible)
        #expect(state.apply(.menu) == .hide)
        #expect(!state.isVisible)
        #expect(state.menuExits)
        #expect(state.apply(.menu) == .exit)
        #expect(state.phase == .dismissed)
        // Menu keeps exiting; the state never swallows a second "back".
        #expect(state.apply(.menu) == .exit)
    }

    @Test func swipeDownShowsAndSwipeUpHides() {
        var state = AppleTVLiveFooterState()
        #expect(state.apply(.swipeDown) == .show)
        #expect(state.isVisible)
        #expect(state.apply(.swipeDown) == .none)
        #expect(state.apply(.swipeUp) == .hide)
        #expect(!state.isVisible)
        #expect(state.apply(.swipeUp) == .none)
    }

    @Test func menuAfterSwipeUpExits() {
        var state = AppleTVLiveFooterState()
        state.apply(.swipeDown)
        state.apply(.swipeUp)
        #expect(state.menuExits)
        #expect(state.apply(.menu) == .exit)
    }

    @Test func swipeDownReopensADismissedFooterAndMenuHidesItAgain() {
        var state = AppleTVLiveFooterState()
        state.apply(.menu)
        state.apply(.menu)
        #expect(state.apply(.swipeDown) == .show)
        #expect(state.apply(.menu) == .hide)
        #expect(state.apply(.menu) == .exit)
    }

    @Test func selectOnTheSurfaceShowsTheFooter() {
        var state = AppleTVLiveFooterState()
        #expect(state.apply(.select) == .show)
        #expect(state.apply(.select) == .none)
        state.apply(.swipeUp)
        #expect(state.apply(.select) == .show)
    }

    @Test func swipeUpOnAFreshPlayerIsIgnored() {
        var state = AppleTVLiveFooterState()
        #expect(state.apply(.swipeUp) == .none)
        #expect(state.phase == .hidden)
        // Still fresh: the next Menu shows the footer instead of exiting.
        #expect(state.apply(.menu) == .show)
    }

    @Test func selectingAChannelOnlySwitchesWhileTheFooterIsShown() {
        var state = AppleTVLiveFooterState()
        #expect(state.apply(.channelSelected) == .none)
        state.apply(.menu)
        #expect(state.apply(.channelSelected) == .switchChannel)
        // The command itself leaves the row up; closing it is the view's
        // move, below, so the machine has one meaning per command.
        #expect(state.isVisible)
    }

    /// What the player does on a card press (owner 18:55: the row stayed over
    /// the picture and the player read as hung): switch, then close the row
    /// and go back to a fresh player, where Menu shows the channels again.
    @Test func resetAfterAChannelSwitchLeavesMenuShowingTheChannelsAgain() {
        var state = AppleTVLiveFooterState()
        state.apply(.menu)
        #expect(state.apply(.channelSelected) == .switchChannel)
        state.reset()
        #expect(!state.isVisible)
        #expect(!state.menuExits)
        #expect(state.apply(.menu) == .show)
    }

    @Test func resetFromADismissedFooterAlsoRestoresMenu() {
        var state = AppleTVLiveFooterState(phase: .dismissed)
        #expect(state.apply(.menu) == .exit)
        state.reset()
        #expect(state.apply(.menu) == .show)
    }

    @Test func focusTargetIsTheCurrentChannelOrTheFirstCard() {
        #expect(AppleTVLiveFooterState.focusTarget(currentID: "b", channelIDs: ["a", "b", "c"]) == "b")
        #expect(AppleTVLiveFooterState.focusTarget(currentID: "z", channelIDs: ["a", "b", "c"]) == "a")
        #expect(AppleTVLiveFooterState.focusTarget(currentID: "z", channelIDs: []) == nil)
    }
}

@Suite("Apple TV guide rail cell model")
struct AppleTVGuideRailCellModelTests {
    @Test func favoriteFlagComesFromTheFavoritesSet() {
        let favorite = AppleTVGuideRailCellModel(channelID: "abc", name: "ABC", number: 7, favoriteIDs: ["abc"])
        let plain = AppleTVGuideRailCellModel(channelID: "cbs", name: "CBS", number: nil, favoriteIDs: ["abc"])
        #expect(favorite.isFavorite)
        #expect(!plain.isFavorite)
    }

    @Test func favoriteGlyphAndTitlesFollowTheFlag() {
        let favorite = AppleTVGuideRailCellModel(channelID: "abc", name: "ABC", number: 7, isFavorite: true)
        #expect(favorite.favoriteGlyph == "heart.fill")
        #expect(favorite.favoriteActionTitle == "Remove from Favorites")
        #expect(favorite.favoriteAccessibilityLabel == "Remove ABC from favorites")

        let plain = AppleTVGuideRailCellModel(channelID: "abc", name: "ABC", number: 7, isFavorite: false)
        #expect(plain.favoriteGlyph == "heart")
        #expect(plain.favoriteActionTitle == "Add to Favorites")
        #expect(plain.favoriteAccessibilityLabel == "Add ABC to favorites")
        #expect(plain.playAccessibilityLabel == "Play ABC")
    }

    @Test func channelNumbersAreNeverGrouped() {
        #expect(AppleTVGuideRailCellModel(channelID: "x", name: "X", number: 1001, isFavorite: false).numberText == "1001")
        #expect(AppleTVGuideRailCellModel(channelID: "x", name: "X", number: nil, isFavorite: false).numberText == nil)
    }

    @Test func longPressOffersPlayThenFavorite() {
        let model = AppleTVGuideRailCellModel(channelID: "x", name: "X", number: nil, isFavorite: false)
        #expect(model.contextActions == [.play, .favorite])
    }

    @Test func togglingFavoriteMatchesTheIOSGuide() {
        let added = AppleTVGuideRailCellModel.togglingFavorite("abc", in: ["cbs"])
        #expect(added == ["abc", "cbs"])
        let removed = AppleTVGuideRailCellModel.togglingFavorite("abc", in: added)
        #expect(removed == ["cbs"])
    }

    /// The heart column is gone: the rail cell is one play target that fills
    /// the rail apart from the gap to the first programme cell.
    @Test func railPlayWidthFillsTheRailApartFromTheColumnGap() {
        let metrics = AppleTVGuideMetrics.standard
        #expect(metrics.railPlayWidth == metrics.railWidth - metrics.cellGap)
        #expect(metrics.railPlayWidth == 254)
        #expect(metrics.railWidth == 260)
    }

    @Test func footerCardsFitInsideTheFooterRow() {
        let metrics = AppleTVGuideMetrics.standard
        #expect(metrics.footerCardSize.height + 2 * 20 <= metrics.footerHeight)
        #expect(metrics.footerLogoSize.width + 2 * 12 <= metrics.footerCardSize.width)
    }
}
