import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Shelf paging")
struct AppleCatalogPagingTests {
    private func item(_ n: Int) -> AppleCatalogItem {
        AppleCatalogItem(mediaID: "tt\(n)", type: "movie", name: "Film \(n)")
    }

    @Test("A page merges without duplicates; paging stops on an empty, short or repeated page")
    func mergeRules() {
        let first = (0..<100).map(item)

        let second = AppleCatalogPaging.merge(first, page: .init(items: (95..<200).map(item), receivedCount: 105),
                                              pageSize: 100)
        #expect(second.items.count == 200)
        #expect(Set(second.items.map(\.id)).count == 200)
        #expect(!second.isExhausted)

        #expect(AppleCatalogPaging.merge(first, page: .init(items: [], receivedCount: 0), pageSize: 100).isExhausted)
        let short = AppleCatalogPaging.merge(first, page: .init(items: (100..<140).map(item), receivedCount: 40),
                                             pageSize: 100)
        #expect(short.items.count == 140 && short.isExhausted)
        let repeated = AppleCatalogPaging.merge(first, page: .init(items: first, receivedCount: 100), pageSize: 100)
        #expect(repeated.items.count == 100 && repeated.isExhausted)
    }

    @Test("The next page is asked for near the end of the row only")
    func nearEnd() {
        let items = (0..<20).map(item)
        #expect(!AppleCatalogPaging.isNearEnd(itemID: items[10].id, in: items))
        #expect(AppleCatalogPaging.isNearEnd(itemID: items[15].id, in: items))
        #expect(AppleCatalogPaging.isNearEnd(itemID: items[19].id, in: items))
        #expect(!AppleCatalogPaging.isNearEnd(itemID: "movie:nope", in: items))
    }
}
