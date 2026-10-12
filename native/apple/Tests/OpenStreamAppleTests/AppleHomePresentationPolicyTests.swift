import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleHomePresentationPolicyTests {
    @Test func heroSelectionPreservesDiscoverLayouts() {
        #expect(AppleHomePresentationPolicy.hero(platform: .mac) == .mac)
        #expect(AppleHomePresentationPolicy.hero(platform: .tv) == .tv)
        #expect(AppleHomePresentationPolicy.hero(platform: .vision) == .rotating)
        #expect(AppleHomePresentationPolicy.hero(platform: .phone, compact: true) == .phone)
        #expect(AppleHomePresentationPolicy.hero(platform: .phone, compact: true, landscape: true) == .rotating)
        #expect(AppleHomePresentationPolicy.hero(platform: .pad) == .pad)
        #expect(AppleHomePresentationPolicy.hero(platform: .pad, accessibility: true) == .rotating)
    }
    @Test func rowResolutionMatchesBothTabs() {
        #expect(AppleHomePresentationPolicy.rows(hero: .phone, width: 390, inset: 16) == .phone)
        #expect(AppleHomePresentationPolicy.rows(hero: .mac, width: 1440, inset: 40) == .mac(contentWidth: 1440, inset: 40))
        for hero in [AppleHomePresentationPolicy.Hero.pad, .tv, .rotating] {
            #expect(AppleHomePresentationPolicy.rows(hero: hero, width: 1024, inset: 16) == nil)
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
