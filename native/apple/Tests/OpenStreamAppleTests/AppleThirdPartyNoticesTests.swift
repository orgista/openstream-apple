import Foundation
import Testing
@testable import OpenStreamApple

@Test func appleThirdPartyNoticesHasAtLeastFiveEntries() {
    let notices = AppleThirdPartyNotices.all()
    #expect(notices.count >= 5)
}

@Test func appleThirdPartyNoticesEveryTextIsLongerThan200Characters() {
    let notices = AppleThirdPartyNotices.all()
    #expect(!notices.isEmpty)
    for notice in notices {
        #expect(notice.text.count > 200)
        #expect(!notice.text.isEmpty)
    }
}

@Test func appleThirdPartyNoticesNamesIncludeAetherEngineAndFFmpeg() {
    let names = AppleThirdPartyNotices.all().map(\.name)
    #expect(names.contains("AetherEngine"))
    #expect(names.contains("FFmpeg"))
}

@Test func appleThirdPartyNoticesAreSortedByName() {
    let names = AppleThirdPartyNotices.all().map(\.name)
    #expect(names == names.sorted())
}

@Test func appleThirdPartyNoticesExposePlainMetadata() {
    for notice in AppleThirdPartyNotices.all() {
        #expect(!notice.name.isEmpty)
        #expect(!notice.license.isEmpty)
        #expect(notice.url.hasPrefix("https://"))
    }
}
