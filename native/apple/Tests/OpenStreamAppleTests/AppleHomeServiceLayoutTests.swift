import Foundation
import Testing
@testable import OpenStreamApple

struct AppleHomeServiceLayoutTests {
    @Test func buttonsUseTheApprovedPlatformSizes() {
        #expect(AppleHomeServiceLayout.buttonSize(regularWidth: false, platform: .tvOS) == CGSize(width: 300, height: 112))
        #expect(AppleHomeServiceLayout.buttonSize(regularWidth: true, platform: .iOS) == CGSize(width: 200, height: 72))
        #expect(AppleHomeServiceLayout.buttonSize(regularWidth: false, platform: .iOS) == CGSize(width: 140, height: 56))
    }

    @Test func gridsFitFourTVPostersThreePhonePostersAndAdaptivePadPosters() {
        let tv = AppleHomeServiceLayout(width: 1760, regularWidth: true, platform: .tvOS)
        #expect(tv.columnCount == 4 && tv.posterWidth == AppleCatalogCard.width(sizing: .portraitPromo, rowStyle: nil,
            scaledCardWidth: 140, viewportWidth: 1920, regularWidth: true, platform: .tvOS))
        #expect(tv.columnGap == 32 && tv.rowGap == AppleTVBillboardMetrics.sectionSpacing)
        #expect(CGFloat(tv.columnCount) * tv.posterWidth + CGFloat(tv.columnCount - 1) * tv.columnGap <= 1760)
        let phone = AppleHomeServiceLayout(width: 393, regularWidth: false, platform: .iOS)
        #expect(phone.columnCount == 3 && phone.columnGap == 10)
        #expect(phone.posterWidth * 3 + 20 + phone.inset * 2 == 393)
        for width: CGFloat in [768, 1024, 1366] {
            let pad = AppleHomeServiceLayout(width: width, regularWidth: true, platform: .iOS)
            #expect((160...200).contains(pad.posterWidth))
            #expect(pad.columnGap == 14)
        }
    }

    @Test @MainActor func servicesOccupyTheSecondRowAndHidingThemDoesNotClaimTitles() {
        let rails = AppleDiscoverView.discoverRails(continueWatching: [], hasLibrary: true, recommendations: .init(),
            top10: nil, serverShelfIDs: [], hasServices: true)
        #expect(rails == [.services, .library])
        let rows = AppleDiscoverRowOrder.rows([.init(id: "continueWatching", keys: ["resume"]),
            .init(id: "services", keys: ["service:netflix"]),
            .init(id: "recentlyAdded", keys: (0..<6).map { "title-\($0)" })])
        #expect(rows.map(\.id) == ["continueWatching", "services", "recentlyAdded"])
        #expect(AppleDiscoverView.displayedRowIDs([.services, .library],
            keys: [["service:netflix"], (0..<6).map { "title-\($0)" }], seedMinimumCounts: [], hiddenRows: ["services"])
            == [[], (0..<6).map { "title-\($0)" }])
    }
}
