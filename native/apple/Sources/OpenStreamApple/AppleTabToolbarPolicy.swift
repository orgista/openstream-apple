/// The trailing toolbar items each tab draws.
///
/// Discover and Library carry the same two, in the same order and drawn by the
/// same `AppleTabToolbar` (owner, 2026-09-24: Discover showed Search + Refresh
/// while Library showed Sort + Refresh). Library's Sort went ("don't need
/// it"). Apple TV draws none: Search is its own tab there and nothing floats
/// over the billboard (X4). Live and Settings keep their own.
enum AppleTabToolbarPolicy {
    enum Item: String, CaseIterable, Sendable { case search, refresh }

    static func items(for tab: OpenStreamTab, isTV: Bool = isTVPlatform, isTitlePage: Bool = false) -> [Item] {
        guard !isTV else { return [] }
        switch tab {
        case .home, .library: return isTitlePage ? [.search] : [.search, .refresh]
        case .search, .live, .settings: return []
        }
    }

    /// The toolbar item's identity. Only the Mac rekeys Refresh when it starts or
    /// stops (its toolbar caches an item's view by identity, N37). On iOS the
    /// same rekey added and removed a bar item while the tab appeared and its
    /// catalog began loading, and UIKit asserts in UINavigationBar layout when
    /// the bar changes mid-transition (TestFlight 10/12, iOS 18.7).
    static func slotID(scope: String, item: Item, isRefreshing: Bool,
                       rekeysBusyItem: Bool = rekeysBusyItemOnPlatform) -> String {
        let busy = rekeysBusyItem && item == .refresh && isRefreshing
        return "\(scope).\(item.rawValue)\(busy ? ".busy" : "")"
    }

    static var rekeysBusyItemOnPlatform: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static var isTVPlatform: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }
}
