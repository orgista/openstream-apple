import XCTest

/// Walks every Apple TV Settings pane with the remote (owner 2026-11-04: "settings on apple tv there a bunch of
/// sections you can't click"). Selecting a section must move focus into its pane, every row in the pane must take
/// focus, and selecting a row must do something: open a page, a menu or a dialog, or change its value.
///
/// The device walk preserves its existing setup. Simulator cases also cover an empty install and a fixed lineup.
/// Rows that delete or rewrite data and the tab visibility switches are only focused.
/// Saved preference switches are exercised only in the fixed simulator case.
@MainActor
final class AppleTVSettingsWalkUITests: OpenStreamUITestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    private let remote = XCUIRemote.shared
    private var lines: [String] = []
    private var fixedState = false

    /// The sidebar's order (`AppleTVSettingsSection.allCases`). A section missing here made `focusSidebar` press
    /// Down on it, then Up from the next one, until it gave up (walk b20r18: Home Rows unwalked, and every pane
    /// after Sources whose return landed on Home Rows was reported as unreachable).
    private static let sections = ["sources", "channels", "restrictions", "liveTV", "general", "homeRows", "services",
                                   "playback", "privacy", "storage", "about"]
    /// Selecting these deletes or rewrites data, so the walk only checks that they take focus.
    private static let focusOnly = ["Clear Cache", "Clear Metadata", "Delete All Downloads", "Remove",
                                    "settings.storage.cache", "settings.storage.metadata", "settings.storage.downloads",
                                    "sources.icloud.resume", "sources.icloud.syncNow", "settings.health.check", "settings.health.stop", "Forget",
                                    "settings.homeRows.resetAll"]
    /// Flipping these rebuilds the tab bar under the walk, so they are only focused.
    private static let tabSwitches = ["settings.discover.enabled", "settings.library.enabled", "settings.live.enabled"]
    /// Off by design in one state each: the last tab still shown, Top 10 before TMDB is set up, and the channel check
    /// while a live channel plays.
    private static let mayBeDisabled = tabSwitches + ["settings.discover.top10", "settings.health.check"]
    /// Read-only rows, as in the system's own About page: they must take focus, and have nothing to open.
    private static let infoRows = ["settings.about.version", "settings.about.build"]

    func testEverySettingsRowFocusesAndOpens() throws {
        executionTimeAllowance = 40 * 60
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        try openSettingsTab()
        walkSections()
        verifyVisibleTabs()
        attachReport()
    }

    func testEmptySettingsPanesKeepFocus() throws {
        fixedState = true
        #if targetEnvironment(simulator)
        app.launchArguments = try simulatorArguments() + ["-OpenStreamSettingsWalkFixture", "empty"]
        #else
        app.launchArguments = ["-OpenStreamSettingsWalkFixture", "empty", "-OpenStreamMuteAudio", "YES"]
        #endif
        app.launch()
        try openSettingsTab()
        try verifyEmptyPanes(expectZeroCache: true)
        attachReport()
    }

    private func verifyEmptyPanes(expectZeroCache: Bool) throws {
        for section in ["storage", "channels", "storage", "channels"] {
            guard let edge = enterPane(section) else { return }
            XCTAssertTrue(focusStaysInPane(sidebarEdge: edge), "\(section): focus bounced back after Select")
            let root = try app.snapshot()
            let ids = flatten(root).map(\.identifier)
            if section == "storage" {
                XCTAssertTrue(ids.contains("settings.storage.cache"), "Empty Storage must retain Clear Cache")
                XCTAssertFalse(ids.contains("settings.storage.metadata"))
                XCTAssertFalse(ids.contains("settings.storage.downloads"))
                let cache = try XCTUnwrap(flatten(root).first { $0.identifier == "settings.storage.cache" })
                XCTAssertTrue(flatten(root).filter(\.hasFocus).contains { holds($0, cache.frame) })
                if expectZeroCache {
                    XCTAssertTrue(flatten(cache).contains { $0.label == "0 bytes" || $0.label.hasSuffix(", 0 bytes") },
                                  "Empty Storage must report zero cache usage")
                }
                log(section, expectZeroCache ? "zero cache" : "empty install", "Clear Cache focused; focus stays in pane")
            } else {
                XCTAssertTrue(ids.contains("channels.empty"), "This case must have an empty lineup")
                XCTAssertFalse(ids.contains("channels.add"))
                log(section, "empty lineup", "focus stays in pane")
            }
            attachScreen("\(expectZeroCache ? "empty" : "empty-install")-\(section)")
        }
    }

    #if targetEnvironment(simulator)
    func testEmptyInstallPanesKeepFocus() throws {
        fixedState = true
        app.launchArguments = try simulatorArguments()
        app.launch()
        try openSettingsTab()
        try verifyEmptyPanes(expectZeroCache: false)
        attachReport()
    }

    func testEverySettingsRowWithFixedLineup() throws {
        executionTimeAllowance = 40 * 60
        fixedState = true
        app.launchArguments = try simulatorArguments() + ["-OpenStreamSettingsWalkFixture", "lineup"]
        app.launch()
        try openSettingsTab()
        walkSections()
        for row in ["Hidden channels", "Reorder favorites", "channels.add"] {
            XCTAssertTrue(lines.contains { $0.contains(row) && $0.contains("opens a page") }, "Fixture did not exercise \(row)")
        }
        verifyVisibleTabs()
        attachReport()
    }

    private func simulatorArguments() throws -> [String] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("settings-walk-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try Data(#"{"version":1,"sources":[]}"#.utf8).write(to: root.appendingPathComponent("dev-sources.json"))
        let playlist = root.appendingPathComponent("fixture.example/settings/channels.m3u.json")
        try FileManager.default.createDirectory(at: playlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="one" group-title="Fixture",Fixture One
        https://fixture.example/live/one.ts
        #EXTINF:-1 tvg-id="two" group-title="Fixture",Fixture Two
        https://fixture.example/live/two.ts
        #EXTINF:-1 tvg-id="three" group-title="Fixture",Fixture Three
        https://fixture.example/live/three.ts
        """.utf8).write(to: playlist)
        let providers = root.appendingPathComponent("api.themoviedb.org/3/watch/providers/movie.json")
        try FileManager.default.createDirectory(at: providers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"results":[{"provider_id":1,"provider_name":"Fixture Service","display_priority":1}]}"#.utf8)
            .write(to: providers)
        return ["-OpenStreamStubNetwork", root.path, "-OpenStreamStubPlaylistStall", "2",
                "-OpenStreamResetOnLaunch", "YES",
                "-OpenStreamUITestFixtureCredentials", "YES", "-OpenStreamMuteAudio", "YES",
                "-OpenStreamTrace", "YES", "-openstream.firstRunGuidanceSeen", "YES",
                "-openstream.reset.cloudRestoreHeld.v1", "YES"]
    }
    #endif

    private func walkSections() {
        let only = ProcessInfo.processInfo.environment["SETTINGSWALK_SECTIONS"]?.split(separator: ",").map(String.init)
        if let root = try? app.snapshot() {
            let drawn = flatten(root).map(\.identifier).filter { $0.hasPrefix("settings.section.") }
                .map { String($0.dropFirst("settings.section.".count)) }
            for section in drawn where !Self.sections.contains(section) { fail("the walk does not know section \(section)") }
        }
        for section in Self.sections where only?.contains(section) ?? true {
            guard app.state == .runningForeground else {
                fail("the app left the foreground before \(section)")
                return
            }
            walk(section)
        }
    }

    private func attachReport() {
        let report = XCTAttachment(string: lines.joined(separator: "\n"))
        report.name = "settings-walk"
        report.lifetime = .keepAlways
        add(report)
    }

    private func verifyVisibleTabs() {
        for (section, id) in [("general", "settings.discover.enabled"), ("liveTV", "settings.live.enabled")] {
            guard let edge = enterPane(section) else { return }
            toTopOfPane(sidebarEdge: edge)
            var checked = false
            for _ in 0..<25 {
                guard let root = try? app.snapshot(), let leaf = focusedLeaf(root), inPane(leaf, sidebarEdge: edge) else { break }
                if let cell = paneCells(root, sidebarEdge: edge).first(where: { allIdentifiers($0).contains(id) }) {
                    let isOn = flatten(cell).contains {
                        ["1", "On"].contains($0.value.map { "\($0)" } ?? "") || $0.label == "On" || $0.label.hasSuffix(", On")
                    }
                    XCTAssertTrue(isOn, "\(id) must remain On")
                    log(section, id, "verified On without selecting")
                    checked = true
                    break
                }
                remote.press(.down)
            }
            XCTAssertTrue(checked, "\(id) must be checked")
            attachScreen("\(section)-tab-remains-on")
        }
    }

    /// Through the tab bar, as a viewer gets there: the app may open on Live and take focus there.
    private func openSettingsTab() throws {
        let tab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        for _ in 0..<12 where !app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            remote.press(.up)
            usleep(300_000)
        }
        for _ in 0..<6 where !tab.hasFocus {
            remote.press(.right)
            usleep(300_000)
        }
        XCTAssertTrue(tab.hasFocus, "Cannot focus the Settings tab")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.section.sources"].waitForExistence(timeout: 15))
    }

    // MARK: - One pane

    private func enterPane(_ section: String) -> CGFloat? {
        guard focusSidebar(section), let sidebarEdge = sidebarRow(section)?.frame.maxX else {
            fail("\(section): the sidebar row never took focus")
            return nil
        }
        remote.press(.select)
        guard waitForFocus(where: { self.inPane($0, sidebarEdge: sidebarEdge) }, timeout: 3) else {
            fail("\(section): selecting the sidebar row does not move into the pane")
            return nil
        }
        log(section, "sidebar", "select → pane")
        return sidebarEdge
    }

    private func focusStaysInPane(sidebarEdge: CGFloat) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            guard let leaf = (try? app.snapshot()).flatMap(focusedLeaf), inPane(leaf, sidebarEdge: sidebarEdge) else { return false }
        } while Date() < deadline
        return true
    }

    private func walk(_ section: String) {
        guard let sidebarEdge = enterPane(section) else { return }
        XCTAssertTrue(focusStaysInPane(sidebarEdge: sidebarEdge), "\(section): focus bounced back after Select")
        toTopOfPane(sidebarEdge: sidebarEdge)
        attachScreen("pane-\(section)")

        var order: [String] = []
        var rows: [String: XCUIElementSnapshot] = [:]
        var focusedKeys = Set<String>()
        var lastKey: String?
        var stuck = 0
        for _ in 0..<160 {
            guard let root = try? app.snapshot() else { break }
            for cell in paneCells(root, sidebarEdge: sidebarEdge) {
                let key = rowKey(cell)
                if rows[key] == nil { order.append(key) }
                rows[key] = cell
            }
            guard let leaf = focusedLeaf(root), inPane(leaf, sidebarEdge: sidebarEdge) else { break }
            let cell = paneCells(root, sidebarEdge: sidebarEdge).first { contains($0, leaf) }
            let current = cell.map(rowKey) ?? "\(leaf.identifier)|\(leaf.label)"
            if !focusedKeys.contains(current) {
                focusedKeys.insert(current)
                let rowLabels = flatten(cell ?? leaf).map(\.label) + [current]
                if Self.focusOnly.contains(where: { excluded in rowLabels.contains { $0.contains(excluded) } }) {
                    log(section, current, "focus only (changes data)")
                } else if allIdentifiers(cell ?? leaf).contains(where: Self.tabSwitches.contains) {
                    log(section, current, "focus only (rebuilds the tab bar)")
                } else if !fixedState, isSwitch(leaf) {
                    log(section, current, "focus only (preserves device preference)")
                } else if let cell, allIdentifiers(cell).contains(where: Self.infoRows.contains) {
                    log(section, current, "focus only (read-only)")
                } else {
                    select(section: section, row: current, leaf: leaf, root: root, sidebarEdge: sidebarEdge)
                }
            }
            if current == lastKey { stuck += 1 } else { stuck = 0 }
            if stuck >= 2 {
                // Down no longer moves: that must be the pane's last row, not a row focus cannot leave.
                let bottom = (cell ?? leaf).frame.maxY
                if let below = paneCells(root, sidebarEdge: sidebarEdge, onScreenOnly: false)
                    .first(where: { $0.frame.minY >= bottom - 1 && !contains($0, leaf) }) {
                    fail("\(section): focus cannot move down from \(current) to \(rowKey(below))")
                }
                break
            }
            lastKey = current
            remote.press(.down)
            usleep(350_000)
        }
        for key in order where !focusedKeys.contains(key) {
            if !fixedState, let cell = rows[key], allIdentifiers(cell).contains(where: Self.mayBeDisabled.contains) {
                log(section, key, "disabled by design")
            } else {
                fail("\(section): row cannot take focus: \(key)")
            }
        }
    }

    // MARK: - Selecting a row

    private func select(section: String, row: String, leaf: XCUIElementSnapshot, root: XCUIElementSnapshot,
                        sidebarEdge: CGFloat) {
        let before = signature(root)
        remote.press(.select)
        var after: XCUIElementSnapshot?
        for _ in 0..<40 {
            usleep(250_000)
            after = try? app.snapshot()
            if let after, signature(after) != before { break }
        }
        guard let after, signature(after) != before else {
            fail("\(section): selecting does nothing: \(row)")
            return
        }
        if !sidebarVisible() {
            log(section, row, "opens a page")
            let ready = waitFor({
                guard let snapshot = try? self.app.snapshot() else { return false }
                return !self.flatten(snapshot).contains { $0.elementType == .activityIndicator && $0.label == "Loading" }
            }, timeout: 15)
            guard ready else { fail("\(section): page never finished loading: \(row)"); return }
            if ["settings.about.privacy", "settings.about.support"].contains(row) {
                XCTAssertTrue(waitForFocus(where: { self.allIdentifiers($0).contains("settings.about.link.url") }, timeout: 3),
                              "\(row): the URL row must take focus")
            }
            attachScreen("page-\(section)-\(row.prefix(40))")
            let rootRows = Set((paneCells(root, sidebarEdge: sidebarEdge) + visibleSidebarRows(root)).map(rowKey))
            if !backToSidebar(section, returningTo: rootRows) { fail("\(section): Menu did not come back from \(row)") }
            return
        }
        let presented = flatten(after).contains { [.alert, .sheet, .keyboard].contains($0.elementType) }
        let now = focusedLeaf(after)
        if !presented, let now, sameControl(now, leaf) {
            if isSwitch(leaf), rowContent(now) != rowContent(leaf) {
                log(section, row, "changes value")
                remote.press(.select)
                let restored = waitFor({
                    (try? self.app.snapshot()).flatMap(self.focusedLeaf).map { self.rowContent($0) == self.rowContent(leaf) } ?? false
                }, timeout: 4)
                if !restored { fail("\(section): could not change back: \(row)") }
            } else {
                log(section, row, "changes the pane")
            }
            return
        }
        let paneControls = paneCells(root, sidebarEdge: sidebarEdge).flatMap(flatten)
        if !presented, let now, paneControls.contains(where: { sameControl($0, now) }) {
            fail("\(section): selecting moves focus to another row: \(row) → \(now.label)")
            return
        }
        if !presented, let now, inPane(now, sidebarEdge: sidebarEdge) {
            log(section, row, "changes the pane")
            return
        }
        log(section, row, "opens a menu or dialog")
        remote.press(.menu)
        _ = waitFor({ (try? self.app.snapshot()).flatMap(self.focusedLeaf).map { self.sameControl($0, leaf) } ?? false },
                    timeout: 5)
    }

    // MARK: - Focus and geometry

    /// Snapshot lookups, not element queries: a query that times out while the app is busy ends the test.
    private func sidebarRow(_ section: String) -> XCUIElementSnapshot? {
        (try? app.snapshot()).flatMap { root in
            flatten(root).first { $0.identifier == "settings.section.\(section)" }
        }
    }

    private func visibleSidebarRows(_ root: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        let screen = root.frame
        return flatten(root).filter {
            $0.identifier.hasPrefix("settings.section.") && $0.frame.height > 1
                && $0.frame.minX >= screen.minX && $0.frame.maxX <= screen.maxX && $0.frame.intersects(screen)
        }
    }

    private func sidebarVisible() -> Bool {
        guard let root = try? app.snapshot() else { return false }
        return !visibleSidebarRows(root).isEmpty
    }

    private func focusSidebar(_ section: String) -> Bool {
        guard backToSidebar(section) else { return false }
        let target = "settings.section.\(section)"
        for _ in 0..<32 {
            guard let root = try? app.snapshot(), let leaf = focusedLeaf(root) else { remote.press(.down); continue }
            let rows = visibleSidebarRows(root)
            if let focused = rows.first(where: { holds(leaf, $0.frame) }) {
                if focused.identifier == target { return true }
                // By position, not by a list of names: a row the list lacks cannot send it the wrong way.
                let targetRow = flatten(root).first { $0.identifier == target }
                remote.press((targetRow?.frame.midY ?? .greatestFiniteMagnitude) > focused.frame.midY ? .down : .up)
            } else if let edge = rows.map(\.frame.maxX).max(), leaf.frame.minX > edge {
                remote.press(.left)
            } else {
                remote.press(.down)
            }
            usleep(300_000)
        }
        return false
    }

    /// tvOS reports focus on the row's cell, not on the button inside it.
    private func holds(_ focused: XCUIElementSnapshot, _ frame: CGRect) -> Bool {
        focused.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) && focused.frame.height <= frame.height * 3
    }

    /// Up until the first row. One press past it lands on the tab bar or the sidebar, so step back in.
    private func toTopOfPane(sidebarEdge: CGFloat) {
        for _ in 0..<40 {
            remote.press(.up)
            usleep(300_000)
            guard let leaf = (try? app.snapshot()).flatMap(focusedLeaf) else { return }
            if !inPane(leaf, sidebarEdge: sidebarEdge) {
                remote.press(leaf.frame.minX <= sidebarEdge ? .right : .down)
                _ = waitForFocus(where: { self.inPane($0, sidebarEdge: sidebarEdge) }, timeout: 3)
                return
            }
        }
    }

    /// A pushed page can need a second Menu (a field, then the page). Never a third: on the Settings root, Menu
    /// goes to the tab bar and then out of the app.
    private func backToSidebar(_ section: String, returningTo rootRows: Set<String>? = nil) -> Bool {
        func returned() -> Bool {
            guard let root = try? app.snapshot() else { return false }
            let sidebar = visibleSidebarRows(root)
            guard let edge = sidebar.map(\.frame.maxX).max() else { return false }
            guard let rootRows else { return true }
            guard let leaf = focusedLeaf(root) else { return false }
            return (paneCells(root, sidebarEdge: edge) + sidebar).contains {
                rootRows.contains(rowKey($0)) && (contains($0, leaf) || holds(leaf, $0.frame))
            }
        }
        for _ in 0..<2 where !returned() {
            remote.press(.menu)
            _ = waitFor({ returned() || self.app.state != .runningForeground }, timeout: 12)
            guard app.state == .runningForeground else {
                fail("\(section): Menu left the app")
                return false
            }
        }
        return returned()
    }

    private func inPane(_ element: XCUIElementSnapshot, sidebarEdge: CGFloat) -> Bool {
        element.frame.minX > sidebarEdge && element.frame.minY > app.frame.height * 0.12
    }

    private func waitForFocus(where predicate: @escaping (XCUIElementSnapshot) -> Bool, timeout: TimeInterval) -> Bool {
        waitFor({ (try? self.app.snapshot()).flatMap(self.focusedLeaf).map(predicate) ?? false }, timeout: timeout)
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    // MARK: - Snapshot helpers

    private func flatten(_ element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        [element] + element.children.flatMap(flatten)
    }

    private func focusedLeaf(_ root: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        flatten(root).last { $0.hasFocus }
    }

    private func paneCells(_ root: XCUIElementSnapshot, sidebarEdge: CGFloat, onScreenOnly: Bool = true) -> [XCUIElementSnapshot] {
        let screen = root.frame
        return flatten(root).filter {
            $0.elementType == .cell && $0.frame.minX > sidebarEdge && $0.frame.height > 1
                && (!onScreenOnly || $0.frame.minY >= screen.minY && $0.frame.maxY <= screen.maxY)
        }
    }

    private func contains(_ cell: XCUIElementSnapshot, _ leaf: XCUIElementSnapshot) -> Bool {
        flatten(cell).contains { same($0, leaf) }
    }

    private func same(_ a: XCUIElementSnapshot, _ b: XCUIElementSnapshot) -> Bool {
        sameControl(a, b) && a.frame == b.frame
    }

    /// Frame left out: the row may scroll while it is selected. Label left out when there is an identifier: a
    /// button may retitle itself while it works ("Syncing…").
    private func sameControl(_ a: XCUIElementSnapshot, _ b: XCUIElementSnapshot) -> Bool {
        guard a.elementType == b.elementType, a.identifier == b.identifier else { return false }
        return !a.identifier.isEmpty || a.label == b.label
    }

    /// Identifiers when the row has any, else labels; never values or glyphs. A toggle keeps its key when it flips,
    /// a row when its chevron hides under focus, and Sync Now when its status time moves on.
    private func rowKey(_ cell: XCUIElementSnapshot) -> String {
        let elements = flatten(cell).filter { $0.elementType != .image }
        let identifiers = elements.map(\.identifier).filter { !$0.isEmpty }
        let parts = identifiers.isEmpty ? elements.map(\.label).filter { !$0.isEmpty } : identifiers
        return NSOrderedSet(array: parts).array.compactMap { $0 as? String }.prefix(3).joined(separator: " | ")
    }

    /// A tvOS Toggle row reads On or Off; only those are flipped back.
    private func isSwitch(_ element: XCUIElementSnapshot) -> Bool {
        element.elementType == .switch || flatten(element).contains {
            ["On", "Off", "0", "1"].contains($0.value.map { "\($0)" } ?? "") || ["On", "Off"].contains($0.label)
        }
    }

    /// What a toggle or picker shows, including the values a key leaves out.
    private func rowContent(_ element: XCUIElementSnapshot) -> [String] {
        flatten(element).map { "\($0.identifier)|\($0.label)|\(String(describing: $0.value))" }
    }

    private func allIdentifiers(_ cell: XCUIElementSnapshot) -> [String] {
        flatten(cell).map(\.identifier).filter { !$0.isEmpty }
    }

    private func signature(_ root: XCUIElementSnapshot) -> Set<String> {
        Set(flatten(root).map { "\($0.elementType.rawValue)|\($0.identifier)|\($0.label)|\(String(describing: $0.value))|\($0.hasFocus)" })
    }

    // MARK: - Output

    private func log(_ section: String, _ row: String, _ outcome: String) {
        let line = "SETTINGSWALK \(section) | \(row) | \(outcome)"
        lines.append(line)
        print(line)
    }

    private func fail(_ message: String) {
        lines.append("SETTINGSWALK FAIL \(message)")
        print("SETTINGSWALK FAIL \(message)")
        XCTFail(message)
    }

    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
