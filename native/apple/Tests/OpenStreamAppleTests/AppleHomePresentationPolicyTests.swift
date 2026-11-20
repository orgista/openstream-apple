import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleHomePresentationPolicyTests {
    @Test func heroSelectionPreservesDiscoverLayouts() {
        #expect(AppleHomePresentationPolicy.hero(platform: .mac) == .mac)
        #expect(AppleHomePresentationPolicy.hero(platform: .tv) == .tv)
        // Vision Pro draws the iPad's hero, accessibility sizes included.
        #expect(AppleHomePresentationPolicy.hero(platform: .vision) == .pad)
        #expect(AppleHomePresentationPolicy.hero(platform: .vision, accessibility: true) == .rotating)
        #expect(AppleHomePresentationPolicy.hero(platform: .iOS, compact: true) == .phone)
        #expect(AppleHomePresentationPolicy.hero(platform: .iOS, compact: true, landscape: true) == .rotating)
        #expect(AppleHomePresentationPolicy.hero(platform: .iOS, isLargeLayout: true) == .pad)
        #expect(AppleHomePresentationPolicy.hero(platform: .iOS, accessibility: true, isLargeLayout: true) == .rotating)
    }
    @Test func rowResolutionMatchesBothTabs() {
        #expect(AppleHomePresentationPolicy.rows(hero: .phone, width: 390, inset: 16) == .phone)
        #expect(AppleHomePresentationPolicy.rows(hero: .mac, width: 1440, inset: 40) == .mac(contentWidth: 1440, inset: 40))
        for hero in [AppleHomePresentationPolicy.Hero.pad, .tv, .rotating] {
            #expect(AppleHomePresentationPolicy.rows(hero: hero, width: 1024, inset: 16) == nil)
        }
    }
    @Test func landscapePhonesKeepTheFallbackRowsWhileIPadsUsePadRows() {
        let landscapePhone = AppleHomePresentationPolicy.hero(platform: .iOS, compact: true, landscape: true)
        #expect(AppleHomePresentationPolicy.rows(hero: landscapePhone, width: 844, inset: 16) == nil)
        for accessibility in [false, true] {
            let hero = AppleHomePresentationPolicy.hero(platform: .iOS, accessibility: accessibility, isLargeLayout: true)
            #expect(AppleHomePresentationPolicy.rows(hero: hero, width: 1024, inset: 24, isLargeLayout: true)
                == .pad(contentWidth: 1024))
        }
    }
    @MainActor @Test func providerSortingPreservesAddedOrderAndUsesTitleAndYear() {
        let z = AppleCatalogItem(mediaID: "fixture-z", type: "movie", name: "Zebra", releaseInfo: "2024")
        let a = AppleCatalogItem(mediaID: "fixture-a", type: "movie", name: "Alpha", releaseInfo: "2020")
        #expect(AppleLibraryCatalogSort.sorted([z, a], by: .added).map(\.mediaID) == [z.mediaID, a.mediaID])
        #expect(AppleLibraryCatalogSort.sorted([z, a], by: .title).map(\.mediaID) == [a.mediaID, z.mediaID])
        #expect(AppleLibraryCatalogSort.sorted([z, a], by: .year).map(\.mediaID) == [z.mediaID, a.mediaID])
    }

}
