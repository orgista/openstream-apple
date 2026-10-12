import Foundation

/// Provider order is retained for Added; the other choices apply equally to previews and full lists.
enum AppleLibraryCatalogSort {
    static func sorted(_ items: [AppleCatalogItem], by sort: AppleLibrarySort) -> [AppleCatalogItem] {
        guard sort != .added else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let lhsYear = lhs.element.year ?? lhs.element.releaseInfo.flatMap { Int($0.prefix(4)) } ?? 0
            let rhsYear = rhs.element.year ?? rhs.element.releaseInfo.flatMap { Int($0.prefix(4)) } ?? 0
            if sort == .year, lhsYear != rhsYear { return lhsYear > rhsYear }
            let comparison = lhs.element.name.localizedStandardCompare(rhs.element.name)
            return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
        }.map(\.element)
    }
}
