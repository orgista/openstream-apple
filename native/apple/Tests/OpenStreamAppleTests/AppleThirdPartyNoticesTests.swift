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

/// Every shipped component (Package.resolved minus the unlinked SMBClient).
@Test func appleThirdPartyNoticesListEveryShippedComponent() {
    let names = AppleThirdPartyNotices.all().map(\.name)
    for name in ["AetherEngine", "AMSMB2", "FFmpeg", "dav1d", "libdovi", "libzvbi", "zimg"] {
        #expect(names.contains(name), "missing notice for \(name)")
    }
}

/// AetherEngine's entry points at both the upstream release and our fork;
/// the AMSMB2 text carries libsmb2 and the LGPL; libdovi credits quietvoid.
@Test func appleThirdPartyNoticesCarryTheRequiredAttributions() throws {
    let byName = Dictionary(uniqueKeysWithValues: AppleThirdPartyNotices.all().map { ($0.name, $0) })
    let engine = try #require(byName["AetherEngine"])
    #expect(engine.note.contains(AppleThirdPartyNotices.aetherEngineForkURL))
    #expect(engine.text.contains("APP STORE / DRM EXCEPTION"))
    let smb = try #require(byName["AMSMB2"])
    #expect(smb.text.contains("libsmb2"))
    #expect(smb.text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    let dovi = try #require(byName["libdovi"])
    #expect(dovi.text.contains("quietvoid"))
    let ffmpeg = try #require(byName["FFmpeg"])
    #expect(ffmpeg.text.contains("Version 2.1, February 1999"))
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
