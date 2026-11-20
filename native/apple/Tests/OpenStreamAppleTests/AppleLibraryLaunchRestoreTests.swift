import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Library launch restore")
struct AppleLibraryLaunchRestoreTests {
    @Test func restoresInSavedOrderAndFiltersInactiveSourcesAndSupplementalFiles() async {
        let active = UUID(), inactive = UUID()
        typealias Snapshot = AppleLocalLibraryStore.AppleLibraryGroupSnapshot
        func item(_ path: String, source: UUID) -> Snapshot.Item {
            .init(id: path, sourceID: source, name: (path as NSString).lastPathComponent,
                url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path,
                sizeBytes: 1, addedAt: .distantPast, modifiedAt: nil)
        }
        let snapshots = (0..<25).map { index in
            Snapshot(id: "title-\(index)", title: "Fixture \(index)", year: 2020, kind: .movie,
                items: [item("Movies/Fixture \(index) (2020)/Fixture \(index) (2020).mkv", source: active),
                    item("Movies/Fixture \(index) (2020)/Extras/Trailer.mkv", source: active),
                    item("Movies/Inactive \(index) (2020).mkv", source: inactive)])
        } + [Snapshot(id: "inactive", title: "Inactive", year: nil, kind: .movie,
            items: [item("Inactive.mkv", source: inactive)])]
        let groups = await AppleLocalLibraryStore.restoredGroups(snapshots, activeSourceIDs: [active])
        #expect(groups.map(\.id) == (0..<25).map { "title-\($0)" })
        #expect(groups.allSatisfy { $0.items.count == 1 && $0.items[0].sourceID == active })
        #expect(groups.map(\.parsed.title) == (0..<25).map { "Fixture \($0)" })
    }
}
