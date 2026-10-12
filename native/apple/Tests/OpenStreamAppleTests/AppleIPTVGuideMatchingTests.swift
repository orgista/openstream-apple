import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Guide channel matching")
struct AppleIPTVGuideMatchingTests {
    @Test func exactIDWinsAndNamesIgnoreDecoration() {
        let names = ["one": "UK | BBC One FHD", "two": "BBC Two HD"]
        #expect(AppleIPTVGuideMatching.match(id: "two", name: "BBC One", names: names)?.confidence == 1)
        #expect(AppleIPTVGuideMatching.match(id: "two", name: "BBC One", names: names)?.channelID == "two")
        #expect(AppleIPTVGuideMatching.match(id: "missing", name: "bbc-one 4K", names: names)?.channelID == "one")
        #expect(AppleIPTVGuideMatching.match(id: nil, name: "BBC One", names: names)?.confidence == 0.95)
    }

    @Test func ambiguousAndEmptyNamesNeverAutoAssign() {
        #expect(AppleIPTVGuideMatching.match(id: nil, name: "News HD", names: ["a": "News", "b": "News FHD"]) == nil)
        #expect(AppleIPTVGuideMatching.match(id: nil, name: "HD", names: ["a": "4K"]) == nil)
        #expect(AppleIPTVGuideMatching.match(id: nil, name: "BBC One", names: ["a": "BBC Two"]) == nil)
    }

    @Test func parserRetainsDisplayNames() {
        let guide = AppleIPTVGuideXMLTVParser().guide(data: Data("<tv><channel id=\"a\"><display-name>BBC One</display-name></channel></tv>".utf8))
        #expect(guide.channelNames == ["a": "BBC One"])
    }

    @Test func xtreamAssignmentsOverrideTheStreamIDAndRejectInvalidValues() {
        #expect(AppleIPTVGuideMatching.xtreamID("source:101", sourceKey: "source") == 101)
        #expect(AppleIPTVGuideMatching.xtreamID("source:101", manualID: "202", sourceKey: "source") == 202)
        #expect(AppleIPTVGuideMatching.xtreamID("source:101", manualID: "-1", sourceKey: "source") == 101)
        #expect(AppleIPTVGuideMatching.xtreamID("invalid") == nil)
    }

    @MainActor @Test func xtreamCatalogueAndAssignmentChangesRefreshImmediately() {
        let source = UUID()
        let id = "\(source.uuidString):101"
        let store = AppleIPTVGuideStore()
        store.channelDisplayNames = [id: "News", "\(UUID().uuidString):202": "Other source"]
        store.configure(xtreamBase: URL(string: "https://fixture.example")!, username: "fixture", password: "fixture", sourceID: source)
        #expect(store.channelNames[source.uuidString] == ["101": "News"])
        let before = store.revision
        store.manualChannelMapping = [id: "202"]
        #expect(store.revision > before)
    }
}
