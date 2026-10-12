import XCTest
import UIKit

/// A UX tour of the iPhone/iPad app with real content: every tab, every
/// Settings page, a movie and a series page, the player and Live. On each
/// screen it lists the buttons, taps every one that is safe to tap, backs out
/// again and writes down what happened (navigated / sheet / nothing / crash).
///
/// Skipped unless the runner has `OPENSTREAM_UX_TOUR=1` (pass it as
/// `TEST_RUNNER_OPENSTREAM_UX_TOUR=1`). Screenshots and the log go to
/// `OPENSTREAM_UX_TOUR_DIR` (a host path; a simulator runner can write there),
/// else they are attached to the result bundle. Destructive or account actions
/// (Delete, Remove, Reset, Sign Out, Sync Now, Import, Download, …) and
/// anything that changes the library (watchlist, ratings, watched marks) are
/// never tapped by the sweep. `testA0Import` imports a passphrase backup the
/// same way `AppleOwnerContentUITests` does (iPhone or iPad Files picker);
/// it runs only with `OPENSTREAM_UX_TOUR_IMPORT=1`. Labels written to the log
/// are redacted of hosts, addresses and e-mail addresses.
@MainActor
final class AppleUXTourUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    private var section = "00"
    private var shotIndex = 0
    private var outDir: URL?
    private var screens = 0
    private var taps = 0
    private var outcomes: [String: Int] = [:]
    private var visitedTitles = Set<String>()
    private var maxPerScreen = 40

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    override func setUpWithError() throws {
        guard environment["OPENSTREAM_UX_TOUR"] == "1" else {
            throw XCTSkip("The UX tour runs only with OPENSTREAM_UX_TOUR=1.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 3600
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        if let dir = environment["OPENSTREAM_UX_TOUR_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
        if let max = environment["OPENSTREAM_UX_TOUR_MAX"].flatMap(Int.init) { maxPerScreen = max }
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    override func tearDown() {
        log("SUMMARY \(device) section=\(section) screens=\(screens) taps=\(taps) "
            + outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Sections

    func testA0Import() throws {
        section = "00-import"
        guard environment["OPENSTREAM_UX_TOUR_IMPORT"] == "1" else { throw XCTSkip("no import asked for") }
        let file = environment["OPENSTREAM_BACKUP_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "OpenStream-owner-backup.json"
        guard let passphrase = environment["OPENSTREAM_BACKUP_PASS"], !passphrase.isEmpty else {
            throw XCTSkip("OPENSTREAM_BACKUP_PASS not set")
        }
        launch(["-OpenStreamVisionScreen", "backup"])
        let importButton = app.buttons["backup.import"].firstMatch
        guard importButton.waitForExistence(timeout: 30) else { return fail("no Import on Backup & Sync") }
        importButton.tap()
        let stem = (file as NSString).deletingPathExtension
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier BEGINSWITH %@", stem, stem)).firstMatch
        if !entry.waitForExistence(timeout: 8) {
            for step in ["Browse", "On My iPhone", "On My iPad", "oStream"] {
                let button = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", step))
                    .allElementsBoundByIndex.first { $0.isHittable }
                if let button { button.tap(); Thread.sleep(forTimeInterval: 1.5) }
                if entry.exists { break }
            }
        }
        guard entry.waitForExistence(timeout: 15) else { return fail("the backup is not in the app's folder") }
        entry.tap()
        let field = app.secureTextFields["backup.import.passphrase"].firstMatch
        guard field.waitForExistence(timeout: 20) else { return fail("the import sheet asked for no passphrase") }
        field.tap()
        field.typeText(passphrase)
        app.buttons["Import"].firstMatch.tap()
        let imported = app.staticTexts["Configuration imported"].firstMatch.waitForExistence(timeout: 90)
        shot("imported")
        log("IMPORT \(imported ? "ok" : "FAILED")")
        XCTAssertTrue(imported, "no \"Configuration imported\" after Import")
        // Background the app before the runner kills it: a kill two seconds
        // after the save, then a reinstall, lost the whole import on a fresh
        // iPad simulator (the preferences were never written out).
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
    }

    func testB1Discover() {
        section = "01-discover"
        let reach = { [unowned self] in self.launch([]); self.tab("Discover"); self.waitForPosters() }
        reach()
        shot("discover-top")
        for index in 1...3 { app.swipeUp(); Thread.sleep(forTimeInterval: 1.5); shot("discover-scrolled-\(index)") }
        for _ in 0..<4 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        explore("discover", depth: 0, reach: reach)
        longPress(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.media.")).firstMatch,
                  "discover-poster", reach: reach)
    }

    func testB2MovieTitlePage() {
        section = "02-title-movie"
        let reach = { [unowned self] in
            self.launch([]); self.tab("Discover"); self.waitForPosters()
            self.openFirstTitle(kind: "movie")
        }
        reach()
        titlePageTour("movie", reach: reach)
    }

    func testB3SeriesTitlePage() {
        section = "03-title-series"
        let query = environment["OPENSTREAM_UX_SERIES"].flatMap { $0.isEmpty ? nil : $0 } ?? "Breaking Bad"
        let reach = { [unowned self] in
            self.launch([]); self.tab("Discover"); self.waitForPosters()
            self.openSearch(); self.search(query)
            let hit = self.app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label BEGINSWITH[c] %@)",
                                                            query, "Search")).firstMatch
            if hit.waitForExistence(timeout: 30) { hit.tap() }
            _ = self.titlePage.waitForExistence(timeout: 30)
        }
        reach()
        let page = titlePage
        log("SERIES page=\(page.exists ? page.identifier : "none")")
        guard page.exists else { return fail("Search did not open a series page for the query") }
        let season = app.buttons["detail.season"].firstMatch
        if season.waitForExistence(timeout: 15) {
            season.tap(); Thread.sleep(forTimeInterval: 1.2); shot("season-menu"); record("season menu", "menu")
            let second = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.season.")).element(boundBy: 1)
            if second.exists, second.isHittable { second.tap(); Thread.sleep(forTimeInterval: 2); shot("season-2") }
            else { dismissOverlay() }
        } else {
            log("  no detail.season on the series page")
        }
        // Search from a title page that was opened from Search (a dead
        // magnifier before 2026-10-08).
        let magnifier = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).allElementsBoundByIndex.first { $0.isHittable }
        if let magnifier {
            magnifier.tap(); taps += 1
            let field = app.searchFields.firstMatch
            let opened = field.waitForExistence(timeout: 5) && !titlePage.exists
            record("Search from a title page opened from Search", opened ? "navigated [Search]" : "nothing happened")
            shot("series-search-from-search")
            reach()
        }
        titlePageTour("series", reach: reach)
    }

    func testB4Player() {
        section = "04-player"
        let reach = { [unowned self] in
            self.launch([]); self.tab("Library")
            let title = self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                              "library.title.", "home.media.")).firstMatch
            if title.waitForExistence(timeout: 240) { Thread.sleep(forTimeInterval: 2); title.tap() }
        }
        reach()
        let play = app.buttons["detail.play"].firstMatch
        guard play.waitForExistence(timeout: 30) else { return fail("no Play on the Library title page") }
        shot("library-title")
        play.tap(); taps += 1
        let quality = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.quality.")).firstMatch
        if quality.waitForExistence(timeout: 4), quality.isHittable { shot("source-choice"); quality.tap() }
        Thread.sleep(forTimeInterval: 15)
        shot("playing-15s-no-controls")
        revealPlayerControls()
        shot("controls")
        let (_, controls) = scan()
        log("SCREEN player buttons=\(controls.count): " + controls.map { redact($0.display) }.joined(separator: " | "))
        let pip = controls.contains { $0.label.localizedCaseInsensitiveContains("Picture in Picture") || $0.identifier.contains("pictureInPicture") }
        let airplay = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "AirPlay")).firstMatch.exists
        log("  PiP button=\(pip) AirPlay=\(airplay)")
        let pause = app.buttons["player.play-pause"].firstMatch
        if pause.exists {
            pause.tap(); taps += 1; Thread.sleep(forTimeInterval: 1); shot("paused"); record("player.play-pause (pause)", "toggled")
            revealPlayerControls()
            if pause.exists { pause.tap(); taps += 1 }
        }
        revealPlayerControls()
        let slider = app.sliders.firstMatch
        if slider.exists {
            slider.adjust(toNormalizedSliderPosition: 0.35); taps += 1
            Thread.sleep(forTimeInterval: 3); shot("scrubbed-35pct"); record("scrubber", "adjusted")
        } else { log("  no slider on the player") }
        var ids = ["player.captions", "player.subtitles", "player.options", "player.more", "player.quality",
                   "player.chapters", "player.sleepTimer", "player.mute", "player.fullscreen"]
        for control in controls where control.identifier.hasPrefix("player.") && !ids.contains(control.identifier)
            && !["player.close", "player.play-pause", "player.controls.show"].contains(control.identifier) {
            ids.append(control.identifier)
        }
        for id in ids {
            revealPlayerControls()
            let button = app.buttons[id].firstMatch
            guard button.exists else { continue }
            guard button.isHittable else { record("\(id) (not hittable)", "unreachable"); continue }
            let before = scan()
            button.tap(); taps += 1
            Thread.sleep(forTimeInterval: 1.2)
            let outcome = classify(before.0)
            let items = scan().1.filter { !before.0.keys.contains($0.key) }.map { redact($0.label) }
            record(id, outcome.0 + (items.isEmpty ? "" : " items: " + items.joined(separator: " | ")))
            shot("player-\(id)")
            if id == "player.mute" { button.tap() } else { dismissPlayerMenu() }
            if !app.descendants(matching: .any).matching(identifier: "player.close").firstMatch.exists {
                log("  the player went away after \(id)")
                break
            }
        }
        closePlayer()
        Thread.sleep(forTimeInterval: 1.5)
        shot("after-close")
        XCTAssertEqual(app.state, .runningForeground, "the app is gone after closing the player")
    }

    func testB5Library() {
        section = "05-library"
        let reach = { [unowned self] in
            self.launch([]); self.tab("Library")
            _ = self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                      "library.title.", "home.media.")).firstMatch.waitForExistence(timeout: 240)
            Thread.sleep(forTimeInterval: 2)
        }
        reach()
        shot("library-top")
        for index in 1...2 { app.swipeUp(); Thread.sleep(forTimeInterval: 1.2); shot("library-scrolled-\(index)") }
        for _ in 0..<3 { app.swipeDown() }
        explore("library", depth: 1, reach: reach)
        longPress(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title.")).firstMatch,
                  "library-title", reach: reach)
    }

    /// Live findings are reported only: another agent owns Live.
    func testB6Live() {
        section = "06-live"
        let reach = { [unowned self] in
            self.launch([]); self.tab("Live")
            let row = self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Play ", "Play preview")).firstMatch
            _ = row.waitForExistence(timeout: 120)
            Thread.sleep(forTimeInterval: 2)
        }
        reach()
        shot("live-top")
        app.swipeUp(); Thread.sleep(forTimeInterval: 1.2); shot("live-scrolled")
        app.swipeDown()
        explore("live", depth: 1, reach: reach)
        reach()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Play ", "Play preview")).firstMatch
        guard row.exists else { return fail("Live lists no channels") }
        row.tap(); taps += 1
        Thread.sleep(forTimeInterval: 20)
        shot("live-channel-20s")
        revealPlayerControls()
        shot("live-channel-controls")
        let (_, controls) = scan()
        log("SCREEN live-player buttons=\(controls.count): " + controls.map { redact($0.display) }.joined(separator: " | "))
        closePlayer()
        Thread.sleep(forTimeInterval: 1.5)
        shot("live-after-close")
    }

    func testB7Search() {
        section = "07-search"
        let reach = { [unowned self] in self.launch([]); self.tab("Discover"); self.waitForPosters(); self.openSearch() }
        reach()
        shot("search-empty")
        explore("search-empty", depth: 0, reach: reach)
        reach()
        let query = environment["OPENSTREAM_OWNER_SEARCH"].flatMap { $0.isEmpty ? nil : $0 } ?? "Inception"
        search(query)
        Thread.sleep(forTimeInterval: 4)
        shot("search-results")
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        let (_, controls) = scan()
        log("SCREEN search-results buttons=\(controls.count)")
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists, clear.isHittable { clear.tap(); taps += 1; Thread.sleep(forTimeInterval: 1); shot("search-cleared"); record("search clear", "cleared") }
        else { log("  no clear button in the search field") }
        search("zzqxj nothing")
        Thread.sleep(forTimeInterval: 5)
        shot("search-no-results")
    }

    func testB8Settings() {
        section = "08-settings"
        let reach = { [unowned self] in self.launch([]); self.tab("Settings"); Thread.sleep(forTimeInterval: 1.5) }
        reach()
        shot("settings-top")
        for index in 1...3 { app.swipeUp(); Thread.sleep(forTimeInterval: 1); shot("settings-scrolled-\(index)") }
        for _ in 0..<4 { app.swipeDown() }
        explore("settings", depth: Int(environment["OPENSTREAM_UX_SETTINGS_DEPTH"] ?? "") ?? 2, pages: 5, reach: reach)
    }

    // MARK: - Title page

    private var titlePage: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
    }

    private func openFirstTitle(kind: String) {
        let details = app.buttons["home.featured.details"].firstMatch
        if details.waitForExistence(timeout: 10), details.isHittable { details.tap() }
        else { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.media.")).firstMatch.tap() }
        _ = titlePage.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 3)
    }

    private func titlePageTour(_ kind: String, reach: @escaping () -> Void) {
        let page = titlePage
        guard page.exists else { return fail("no \(kind) title page") }
        log("TITLE \(kind) page=\(page.identifier)")
        shot("\(kind)-top")
        for index in 1...4 { app.swipeUp(); Thread.sleep(forTimeInterval: 1.2); shot("\(kind)-scrolled-\(index)") }
        for _ in 0..<5 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        // Watchlist: on, picture, off again.
        for id in ["detail.my-list"] {
            let button = app.buttons[id].firstMatch
            guard button.exists, button.isHittable else { log("  \(id) not on screen"); continue }
            let before = button.label
            button.tap(); taps += 1; Thread.sleep(forTimeInterval: 1.2)
            shot("\(kind)-\(id)-on")
            record("\(id) [\(before) -> \(button.label)]", button.label == before ? "nothing happened" : "toggled")
            button.tap(); Thread.sleep(forTimeInterval: 1)
        }
        explore("\(kind)-page", depth: 1, reach: reach)
    }

    // MARK: - The sweep

    private struct Control {
        var key: String
        var group: String
        var label: String
        var identifier: String
        var type: XCUIElement.ElementType
        var frame: CGRect
        var occurrence: Int
        var display: String { identifier.isEmpty ? "\"\(label)\"" : "\(identifier) \"\(label)\"" }
        var short: String { identifier.isEmpty ? label : identifier }
    }

    private struct Signature {
        var title: String
        var keys: Set<String>
        var alert: Bool
        var content: Int
        var overlay = false
    }

    /// The screen's signature from one accessibility snapshot, and its
    /// buttons from one query (a snapshot stops at a fixed depth, which cuts
    /// off the poster shelves; a query does not).
    private func scan(controls wantControls: Bool = true) -> (Signature, [Control]) {
        guard app.state == .runningForeground, let root = try? app.snapshot() else {
            return (Signature(title: "<none>", keys: [], alert: false, content: 0), [])
        }
        var titles: [String] = []
        var keys = Set<String>()
        var alert = false
        var overlay = false
        var hasher = Hasher()
        func walk(_ node: XCUIElementSnapshot, excluded: Bool) {
            var excluded = excluded
            switch node.elementType {
            case .tabBar, .keyboard, .statusBar: excluded = true
            case .alert: alert = true
            case .navigationBar: titles.append(node.identifier.hasPrefix("_Tt") ? "<untitled>" : node.identifier)
            default: break
            }
            if node.identifier == "PopoverDismissRegion" || node.label == "dismiss popup"
                || [.menu, .menuItem, .popover].contains(node.elementType) { overlay = true }
            hasher.combine(node.label)
            hasher.combine(node.elementType.rawValue)
            if let value = node.value as? String { hasher.combine(value) }
            if !excluded, node.elementType == .button || node.elementType == .link {
                keys.insert(node.identifier.isEmpty ? "label:\(node.label)" : "id:\(node.identifier)")
            }
            for child in node.children { walk(child, excluded: excluded) }
        }
        walk(root, excluded: false)
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
        // A title page's nav bar comes and goes as it scrolls: the page is its own title.
        if page.exists { titles = [page.identifier] }
        let signature = Signature(title: titles.joined(separator: " > "), keys: keys, alert: alert, content: hasher.finalize(),
                                  overlay: overlay)
        return (signature, wantControls ? queryControls(window: root.frame) : [])
    }

    private static let controlLine = try! NSRegularExpression(
        pattern: #"^\s*(Button|Link), 0x[0-9a-f]+, \{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}(.*)$"#)
    private static let identifierField = try! NSRegularExpression(pattern: #"identifier: '([^']*)'"#)
    private static let labelField = try! NSRegularExpression(
        pattern: #"label: '(.*?)'(?=, (?:value|placeholderValue|title|Disabled|Selected|Not hittable)|$)"#)

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    private func queryControls(window: CGRect) -> [Control] {
        let excludedFrames = [app.tabBars.firstMatch, app.keyboards.firstMatch].compactMap { $0.exists ? $0.frame : nil }
        var controls: [Control] = []
        var counts: [String: Int] = [:]
        let description = app.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.link.rawValue)).debugDescription
        if environment["OPENSTREAM_UX_TOUR_DEBUG"] == "1", let outDir {
            try? redact(description).write(to: outDir.appendingPathComponent("debug-\(device)-\(section)-\(shotIndex).txt"),
                                           atomically: true, encoding: .utf8)
        }
        for line in description.split(separator: "\n").map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = Self.controlLine.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String { Self.capture(match, index, in: line) }
            let type: XCUIElement.ElementType = group(1) == "Link" ? .link : .button
            let frame = CGRect(x: Double(group(2)) ?? 0, y: Double(group(3)) ?? 0,
                               width: Double(group(4)) ?? 0, height: Double(group(5)) ?? 0)
            let rest = group(6)
            let restRange = NSRange(rest.startIndex..., in: rest)
            let identifier = Self.identifierField.firstMatch(in: rest, range: restRange).map { Self.capture($0, 1, in: rest) } ?? ""
            let label = Self.labelField.firstMatch(in: rest, range: restRange).map { Self.capture($0, 1, in: rest) } ?? ""
            let key = identifier.isEmpty ? "label:\(label)" : "id:\(identifier)"
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard !rest.contains("Disabled"), frame.width >= 4, frame.height >= 4,
                  frame.maxX > window.minX, frame.minX < window.maxX,
                  !excludedFrames.contains(where: { $0.contains(center) }) else { continue }
            controls.append(Control(key: key, group: key, label: label, identifier: identifier,
                                    type: type, frame: frame, occurrence: occurrence))
        }
        // Shelves of posters, rows of channels: one of each kind is enough.
        var groupCounts: [String: Int] = [:]
        for index in controls.indices {
            let control = controls[index]
            if !control.identifier.isEmpty {
                let parts = control.identifier.split(separator: ".")
                if parts.count >= 3 { controls[index].group = parts.dropLast().joined(separator: ".") }
            } else if let first = control.label.split(separator: " ").first, control.label.contains(" ") {
                controls[index].group = "word:\(first)"
            }
            groupCounts[controls[index].group, default: 0] += 1
        }
        for index in controls.indices where groupCounts[controls[index].group, default: 0] < 3
            && !controls[index].group.hasPrefix("word:") {
            controls[index].group = controls[index].key
        }
        for index in controls.indices where controls[index].group.hasPrefix("word:")
            && groupCounts[controls[index].group, default: 0] < 4 {
            controls[index].group = controls[index].key
        }
        controls.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        return controls
    }

    private static let unsafeLabel = try! NSRegularExpression(
        pattern: #"\b(delete|remove|reset|sign (in|out)|log (in|out)|sync now|erase|clear|forget|import|export|disconnect|download|unpair|restore|purchase|buy|subscribe|send|pair|passcode|pin|report|mark|rename|save|add to|watchlist|my list|start over|shareplay|refresh|rescan|scan now|test connection|connect|retry|recheck|re-check|copy|paste|lock|leave|empty|uninstall|deauthori[sz]e|revoke|share setup)\b|^(play|resume|watch live|watch now|continue)\b"#,
        options: [.caseInsensitive])
    private static let unsafeIdentifierPrefixes = [
        "detail.rate.", "detail.my-list", "home.featured.my-list", "home.featured.play", "detail.play", "detail.startOver",
        "detail.next-episode", "detail.episode.", "detail.download", "home.continue.", "player.close", "live.shareplay",
        "search.recent.clear", "backup.", "live.watchLive", "player.watchLive", "detail.quality.", "BackButton",
        "live.picker.channel.", "live.footer.", "search.openCopiedLink",
        // The iPad's tab strip: tabs are visited by their own sections.
        "sparkles", "books.vertical", "dot.radiowaves.left.and.right", "gearshape",
    ]

    private func isSafe(_ control: Control) -> Bool {
        if control.label == "Back" || (control.label.isEmpty && control.identifier.isEmpty) { return false }
        if Self.unsafeIdentifierPrefixes.contains(where: { control.identifier.hasPrefix($0) }) { return false }
        let lowered = control.identifier.lowercased()
        if ["delete", "remove", "reset", "signout", "sign-out", "logout"].contains(where: { lowered.contains($0) }) { return false }
        let range = NSRange(control.label.startIndex..., in: control.label)
        return Self.unsafeLabel.firstMatch(in: control.label, range: range) == nil
    }

    private func explore(_ name: String, depth: Int, pages: Int = 1, reach: @escaping () -> Void) {
        screens += 1
        var (home, all) = scan()
        if pages > 1 {
            // Lazy lists only hold the rows on screen: walk the page once.
            var known = Set(all.map(\.key))
            for _ in 1..<pages {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
                for control in scan().1 where !known.contains(control.key) {
                    known.insert(control.key)
                    all.append(control)
                }
            }
            for _ in 1..<pages { app.swipeDown() }
            Thread.sleep(forTimeInterval: 0.6)
        }
        visitedTitles.insert(home.title)
        var seenGroups = Set<String>()
        var picked: [Control] = []
        var skipped: [String] = []
        for control in all {
            guard !seenGroups.contains(control.group) else { continue }
            seenGroups.insert(control.group)
            if isSafe(control) { picked.append(control) } else { skipped.append(control.display) }
        }
        log("SCREEN \(name) nav=[\(redact(home.title))] buttons=\(all.count) kinds=\(seenGroups.count) "
            + "tapping=\(min(picked.count, maxPerScreen)) skipped(unsafe)=\(skipped.count)")
        if !skipped.isEmpty { log("  unsafe, not tapped: " + skipped.map(redact).joined(separator: " | ")) }
        shot(name)
        for control in picked.prefix(maxPerScreen) {
            guard backTo(home, reach: reach) else { log("  lost the screen; stopping \(name)"); return }
            tapAndRecord(control, screen: name, depth: depth, reach: reach)
        }
        _ = backTo(home, reach: reach)
    }

    private func tapAndRecord(_ control: Control, screen: String, depth: Int, reach: @escaping () -> Void) {
        let element = resolve(control)
        if !element.exists {
            for _ in 0..<6 where !element.exists { app.swipeUp(); Thread.sleep(forTimeInterval: 0.4) }
            for _ in 0..<12 where !element.exists { app.swipeDown(); Thread.sleep(forTimeInterval: 0.4) }
        }
        guard element.exists else { record("\(control.display)", "gone before tap"); return }
        if !element.isHittable {
            let window = app.windows.firstMatch.frame
            for _ in 0..<10 where element.exists && !element.isHittable {
                let frame = element.frame
                if frame.midY > window.midY { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        guard element.isHittable else { record("\(control.display)", "unreachable"); return }
        let before = scan(controls: false).0
        let started = Date()
        element.tap()
        taps += 1
        Thread.sleep(forTimeInterval: 1.5)
        var (outcome, navigated) = classify(before)
        if outcome == "nothing happened" {
            // Slow loads: give it a little longer before calling it dead.
            Thread.sleep(forTimeInterval: 2)
            (outcome, navigated) = classify(before)
            if outcome != "nothing happened" { outcome += " (slow: \(String(format: "%.1f", Date().timeIntervalSince(started)))s)" }
        }
        record(control.display, outcome)
        if outcome != "nothing happened" { shot("\(screen)-\(control.short)") }
        if outcome.hasPrefix("CRASH") {
            launch([])
            reach()
            return
        }
        if navigated, depth > 0 {
            let now = scan(controls: false).0
            if !visitedTitles.contains(now.title) {
                explore("\(screen)-\(slug(control.short))", depth: depth - 1) { [unowned self] in
                    reach()
                    let again = self.resolve(control)
                    if again.waitForExistence(timeout: 5) {
                        for _ in 0..<3 where !again.isHittable { self.app.swipeUp() }
                        if again.isHittable { again.tap(); Thread.sleep(forTimeInterval: 1.5) }
                    }
                }
            }
        }
    }

    private func resolve(_ control: Control) -> XCUIElement {
        let query = app.descendants(matching: control.type == .link ? .link : .button)
        if !control.identifier.isEmpty {
            return query.matching(identifier: control.identifier).element(boundBy: control.occurrence)
        }
        return query.matching(NSPredicate(format: "label == %@", control.label)).element(boundBy: control.occurrence)
    }

    /// What a tap did, compared with the screen before it.
    private func classify(_ before: Signature) -> (String, Bool) {
        switch app.state {
        case .notRunning, .unknown: return ("CRASH (app not running)", false)
        case .runningForeground: break
        default:
            return ("left the app (\(XCUIApplication(bundleIdentifier: "com.apple.springboard").state == .runningForeground ? "home" : "other app"))", false)
        }
        let now = scan(controls: false).0
        if now.alert && !before.alert {
            let text = app.alerts.firstMatch.label
            return ("alert \"\(redact(text))\"", false)
        }
        if now.overlay && !before.overlay { return ("menu opened", false) }
        if now.title.isEmpty && !before.title.isEmpty && jaccard(now.keys, before.keys) >= 0.5 { return ("menu opened", false) }
        if now.title != before.title { return ("navigated [\(redact(now.title))]", true) }
        let overlap = jaccard(now.keys, before.keys)
        if overlap < 0.7 { return ("sheet/menu/changed (overlap \(String(format: "%.2f", overlap)))", false) }
        if now.content != before.content { return ("updated in place", false) }
        return ("nothing happened", false)
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }

    private func same(_ a: Signature, _ b: Signature) -> Bool {
        a.title == b.title && !a.alert && a.overlay == b.overlay && jaccard(a.keys, b.keys) >= 0.3
    }

    /// Backs out of whatever a tap opened until the screen is `home` again;
    /// relaunches and walks back there as a last resort.
    private func backTo(_ home: Signature, reach: () -> Void) -> Bool {
        for _ in 0..<7 {
            if app.state == .notRunning { break }
            if app.state != .runningForeground { app.activate(); Thread.sleep(forTimeInterval: 1.5); continue }
            let now = scan(controls: false).0
            if same(now, home) { return true }
            if now.alert {
                let alert = app.alerts.firstMatch
                let preferred = ["Cancel", "Not Now", "Close", "OK", "Dismiss", "Done"].first { alert.buttons[$0].exists }
                if let preferred { alert.buttons[preferred].tap() } else { alert.buttons.allElementsBoundByIndex.last?.tap() }
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            if dismissOverlayStep(sameTitle: now.title == home.title || now.title.isEmpty, overlay: now.overlay) { continue }
        }
        if same(scan(controls: false).0, home) { return true }
        log("  relaunching to get back to [\(redact(home.title))]")
        launch([])
        reach()
        return same(scan(controls: false).0, home)
    }

    /// One step of backing out. Returns whether it did something.
    @discardableResult
    private func dismissOverlayStep(sameTitle: Bool, overlay: Bool = false) -> Bool {
        let popover = app.otherElements["PopoverDismissRegion"].firstMatch
        if popover.exists { popover.tap(); Thread.sleep(forTimeInterval: 0.8); return true }
        let dismissPopup = app.buttons["dismiss popup"].firstMatch
        if dismissPopup.exists, dismissPopup.isHittable { dismissPopup.tap(); Thread.sleep(forTimeInterval: 0.8); return true }
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if !overlay, close.exists {
            if !close.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); Thread.sleep(forTimeInterval: 0.5) }
            if close.isHittable { close.tap(); Thread.sleep(forTimeInterval: 1.2); return true }
        }
        if sameTitle || overlay {
            // A menu or a context menu over the same screen: tap above it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
            Thread.sleep(forTimeInterval: 0.8)
            return true
        }
        for id in ["detail.back", "live.picker.back", "live.picker.close", "detail.quality.done", "player.quality.done",
                   "detail.watchOn.instructions.done"] {
            let button = app.buttons[id].firstMatch
            if button.exists, button.isHittable { button.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
        }
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.exists, back.isHittable { back.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
        let leading = app.navigationBars.buttons.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minX < 100 }
        if let leading { leading.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
        for label in ["Done", "Cancel", "Close", "Dismiss", "Not Now"] {
            let button = app.navigationBars.buttons[label].firstMatch
            if button.exists, button.isHittable { button.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
        }
        for label in ["Close", "Done", "Cancel"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { $0.isHittable }
            if let button { button.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
        }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        Thread.sleep(forTimeInterval: 1.0)
        return true
    }

    /// Closes a menu over the player without touching the player's own Close.
    private func dismissPlayerMenu() {
        let popover = app.otherElements["PopoverDismissRegion"].firstMatch
        if popover.exists { popover.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap() }
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func dismissOverlay() {
        let before = scan(controls: false).0
        dismissOverlayStep(sameTitle: true)
        if scan(controls: false).0.title != before.title { return }
    }

    private func longPress(_ element: XCUIElement, _ name: String, reach: () -> Void) {
        guard element.waitForExistence(timeout: 10) else { log("  long-press \(name): nothing to press"); return }
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 where element.exists && !element.isHittable {
            if element.frame.midY > window.midY { app.swipeUp() } else { app.swipeDown() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard element.isHittable else { log("  long-press \(name): not hittable"); return }
        let before = scan(controls: false).0
        element.press(forDuration: 1.2)
        taps += 1
        Thread.sleep(forTimeInterval: 1.2)
        let (outcome, _) = classify(before)
        let menu = scan().1.filter { !before.keys.contains($0.key) }.map { redact($0.label) }
        record("long-press \(name)", outcome + (menu.isEmpty ? "" : " items: " + menu.joined(separator: " | ")))
        shot("longpress-\(name)")
        _ = backTo(before, reach: reach)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) {
        app.terminate()
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamTraceConsole", "YES",
                               "-OpenStreamMuteAudio", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    /// The iPhone's tab bar, or the iPad's tab strip at the top (not a tab
    /// bar to XCUITest: plain buttons named for the tab).
    private func tab(_ name: String) {
        let bar = app.tabBars.buttons[name].firstMatch
        if bar.waitForExistence(timeout: UIDevice.current.userInterfaceIdiom == .pad ? 3 : 20) {
            bar.tap()
        } else {
            let strip = app.buttons.matching(NSPredicate(format: "label == %@", name))
            _ = strip.firstMatch.waitForExistence(timeout: 15)
            let top = strip.allElementsBoundByIndex.filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }
            if let top { top.tap() } else { fail("no \(name) tab") }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    private func waitForPosters() {
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.media.")).firstMatch
        if !poster.waitForExistence(timeout: 90) { log("  Discover showed no posters within 90 s") }
        Thread.sleep(forTimeInterval: 3)
    }

    private func openSearch() {
        let search = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).allElementsBoundByIndex.first { $0.isHittable }
        guard let search else { return fail("Discover has no Search") }
        search.tap()
        _ = app.searchFields.firstMatch.waitForExistence(timeout: 10)
    }

    private func search(_ query: String) {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return fail("no search field") }
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(query)
        Thread.sleep(forTimeInterval: 3)
    }

    private func revealPlayerControls() {
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if close.exists && close.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func closePlayer() {
        revealPlayerControls()
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if close.waitForExistence(timeout: 3), close.isHittable { close.tap() } else { log("  no hittable player.close") }
    }

    private func record(_ what: String, _ outcome: String) {
        let kind = outcome.split(separator: " ").first.map(String.init) ?? outcome
        outcomes[kind, default: 0] += 1
        log("  TAP \(redact(what)) -> \(outcome)")
    }

    private func fail(_ message: String) {
        shot("FAIL-\(message)")
        log("FAIL \(message)")
        XCTFail(message)
    }

    private func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        let mapped = redact(text).unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(String(mapped).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static let redactions: [NSRegularExpression] = [
        #"[a-z][a-z0-9+.-]*://\S+"#,
        #"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"#,
        #"[\w.+-]+@[\w-]+(\.[\w-]+)+"#,
        #"\b[\w-]+(\.[\w-]+)*\.(com|net|org|tv|io|me|xyz|cc|co|info|live|top|pro|vip|club|site|online|stream|uk|de|nl|local|lan|fun|app|link|me|ru|eu|cloud|host|world|space)(:\d+)?\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private func redact(_ text: String) -> String {
        var result = text
        for pattern in Self.redactions {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<redacted>")
        }
        return result
    }

    private func shot(_ what: String) {
        shotIndex += 1
        let name = "\(device)-\(section)-\(String(format: "%03d", shotIndex))-\(slug(what))"
        let screenshot = XCUIScreen.main.screenshot()
        if let outDir {
            let image = screenshot.image
            let size = CGSize(width: image.size.width / 2, height: image.size.height / 2)
            let scaled = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = image.scale; return f }())
                .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = scaled.jpegData(compressionQuality: 0.72),
               (try? data.write(to: outDir.appendingPathComponent(name + ".jpg"))) != nil {
                return
            }
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func log(_ line: String) {
        print("UXTOUR \(line)")
        guard let outDir else { return }
        let url = outDir.appendingPathComponent("tour-\(device).log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
