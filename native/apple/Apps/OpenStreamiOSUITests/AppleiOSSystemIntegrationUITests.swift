import XCTest

/// Two things earlier passes called "not scriptable" and skipped.
///
/// Both are: XCUITest drives SpringBoard (`com.apple.springboard`) like any
/// other app, and a `.fileExporter` / `.fileImporter` sheet is a real document
/// picker bridged into the host app's hierarchy. Where a label is not where
/// this expects it, the helpers print the live tree rather than failing blind,
/// so a miss leaves evidence.
///
/// Never enumerate `buttons.allElementsBoundByIndex` on SpringBoard to log it:
/// the keyboard's keys resolve as a different automation type between the
/// query and the property read, and the mismatch fails the test. The tree text
/// from `debugDescription` carries the same information safely.
@MainActor
final class AppleiOSWidgetPlacementUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func tearDown() {
        app?.terminate()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ stage: String) {
        let tree = springboard.debugDescription
        print("=== TREE \(stage) (\(tree.count) chars) ===")
        print(String(tree.prefix(40000)))
        print("=== END \(stage) ===")
    }

    private func firstHittable(_ labels: [String], in element: XCUIElement) -> XCUIElement? {
        for label in labels {
            for query in [element.buttons, element.staticTexts, element.cells, element.otherElements] {
                let match = query.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
                if match.exists, match.isHittable { return match }
            }
        }
        for label in labels {
            let match = element.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
            if match.exists, match.isHittable { return match }
        }
        return nil
    }

    /// The placed widget, as opposed to the app icon: both carry the
    /// identifier `oStream`, and only the widget's value says so.
    private func placedWidget() -> XCUIElement? {
        let icons = springboard.icons.matching(NSPredicate(format: "identifier == %@", "oStream"))
        for icon in icons.allElementsBoundByIndex where icon.exists {
            if String(describing: icon.value).contains("Widget") { return icon }
        }
        return nil
    }

    /// Long-presses the Home Screen until the jiggle/edit affordances appear.
    /// Three candidate spots because the first can land on an app icon, which
    /// opens that icon's context menu instead.
    private func enterEditMode() -> Bool {
        let spots = [CGVector(dx: 0.5, dy: 0.86), CGVector(dx: 0.08, dy: 0.86), CGVector(dx: 0.5, dy: 0.13)]
        for (index, spot) in spots.enumerated() {
            springboard.coordinate(withNormalizedOffset: spot).press(forDuration: 1.6)
            Thread.sleep(forTimeInterval: 2.5)
            if springboard.buttons["Done"].exists || springboard.buttons["Edit"].exists { return true }
            if let edit = firstHittable(["Edit Home Screen"], in: springboard) {
                edit.tap()
                Thread.sleep(forTimeInterval: 2.5)
                if springboard.buttons["Done"].exists || springboard.buttons["Edit"].exists { return true }
            }
            print("EDITMODE spot \(index) did not open edit mode")
            dump("after-press-\(index)")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        return false
    }

    func testContinueWatchingWidgetCanBePlacedOnTheHomeScreen() {
        // The widget reads a snapshot the app publishes into the app group, so
        // run the app once first: a widget added before that draws its
        // placeholder and proves nothing.
        app.launchArguments += ["-OpenStreamVisionScreen", "discover"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app never came to the foreground")
        Thread.sleep(forTimeInterval: 12)
        app.terminate()

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        springboard.activate()
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 30), "SpringBoard never came forward")

        // A previous run that failed part-way leaves one behind.
        removeWidget(stage: "00-pre")
        attach("01-home-screen")

        XCTAssertTrue(enterEditMode(), "long-pressing the Home Screen never produced Done/Edit")
        attach("02-edit-mode")

        // iOS 18/26 put the gallery behind "Edit"; iOS 17 behind a bare "+".
        if let add = firstHittable(["Add Widget", "Add Widgets"], in: springboard) {
            add.tap()
        } else if springboard.buttons["Edit"].exists {
            springboard.buttons["Edit"].tap()
            Thread.sleep(forTimeInterval: 2)
            guard let add = firstHittable(["Add Widget", "Add Widgets", "Customize"], in: springboard) else {
                dump("no-add-widget")
                return XCTFail("the edit menu had no Add Widget entry — tree above")
            }
            add.tap()
        } else {
            dump("no-add-affordance")
            return XCTFail("no Add Widget or Edit control in edit mode — tree above")
        }
        Thread.sleep(forTimeInterval: 3)
        attach("03-widget-gallery")

        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the widget gallery had no search field")
        search.tap()
        search.typeText("oStream")
        Thread.sleep(forTimeInterval: 3)
        attach("04-gallery-search")

        guard let result = firstHittable(["oStream"], in: springboard) else {
            dump("gallery-no-result")
            return XCTFail("searching the gallery for oStream matched nothing — tree above")
        }
        result.tap()
        Thread.sleep(forTimeInterval: 3)
        attach("05-widget-preview")

        guard let confirm = firstHittable(["Add Widget"], in: springboard) else {
            dump("preview-no-add")
            return XCTFail("the widget preview had no Add Widget button — tree above")
        }
        confirm.tap()
        Thread.sleep(forTimeInterval: 4)
        attach("06-just-added")

        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        else { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        Thread.sleep(forTimeInterval: 4)
        attach("07-home-screen-with-widget")
        dump("placed")

        guard let widget = placedWidget() else {
            dump("no-widget")
            return XCTFail("no oStream widget on the Home Screen after adding it — tree above")
        }
        print("WIDGET label=\(widget.label) value=\(String(describing: widget.value)) frame=\(widget.frame)")

        // Real data, not the placeholder: these titles come from the app group
        // snapshot, and the empty path draws a message instead of buttons.
        let titles = widget.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        print("WIDGET titles=\(titles)")
        XCTAssertFalse(titles.isEmpty, "the widget rendered no Continue Watching titles — placeholder, not real data")

        removeWidget(stage: "08")
        attach("09-home-screen-cleaned")
        XCTAssertNil(placedWidget(), "the widget was still on the Home Screen after cleanup")
    }

    /// The owner's simulator has to look the way it did before this ran.
    private func removeWidget(stage: String) {
        guard let widget = placedWidget() else { print("CLEANUP \(stage): nothing to remove"); return }
        // The gallery's search keyboard can still be up; get back to a plain
        // Home Screen before pressing, or the press lands on a key.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.5)
        widget.press(forDuration: 1.6)
        Thread.sleep(forTimeInterval: 3)
        attach("\(stage)-widget-context-menu")
        guard let remove = firstHittable(["Remove Widget"], in: springboard) else {
            dump("\(stage)-remove-menu")
            print("CLEANUP \(stage): no Remove Widget entry — tree above")
            return
        }
        remove.tap()
        Thread.sleep(forTimeInterval: 2.5)
        if springboard.alerts.buttons["Remove"].exists {
            springboard.alerts.buttons["Remove"].tap()
        } else if let confirm = firstHittable(["Remove"], in: springboard) {
            confirm.tap()
        }
        Thread.sleep(forTimeInterval: 3)
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        Thread.sleep(forTimeInterval: 2)
    }
}

/// Export the configuration through the real save sheet, then import the file
/// it wrote back through the real browse sheet.
@MainActor
final class AppleiOSConfigurationTransferUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        app?.terminate()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The picker is a remote view bridged into the app's own hierarchy — it
    /// sits at the very end of the tree, past the whole Backup form, so this
    /// has to print far more than a token slice.
    private func dump(_ stage: String) {
        let tree = app.debugDescription
        print("=== TREE \(stage) (\(tree.count) chars) ===")
        print(String(tree.prefix(40000)))
        print("=== END \(stage) ===")
    }

    private func tap(_ labels: [String]) -> Bool {
        for label in labels {
            for query in [app.buttons, app.cells, app.staticTexts, app.otherElements] {
                let match = query.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
                if match.exists, match.isHittable { match.tap(); return true }
            }
        }
        return false
    }

    private func fileElement() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "openstream-config")).firstMatch
    }

    func testConfigurationExportsThroughTheSaveSheetAndImportsBack() {
        app.launchArguments += ["-OpenStreamVisionScreen", "backup"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app never came to the foreground")

        let export = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export Configuration")).firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 40), "no Export Configuration button on the Backup screen")
        attach("01-backup-screen")
        export.tap()

        // The export itself runs before the sheet can be built.
        Thread.sleep(forTimeInterval: 6)
        attach("02-save-sheet")
        dump("save-sheet")

        // The picker opens wherever it was left. Only steer it if it is not
        // already in local storage — steering it away is how the import half
        // lost the file on the first run.
        let localRoot = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS[c] %@", "com.apple.FileProvider.LocalStorage")).firstMatch
        if !localRoot.exists {
            _ = tap(["Browse"])
            Thread.sleep(forTimeInterval: 2)
            _ = tap(["On My iPhone"])
            Thread.sleep(forTimeInterval: 2)
        }
        attach("03-save-sheet-location")

        let save = app.buttons["Save"]
        guard save.waitForExistence(timeout: 20), save.isHittable else {
            dump("save-sheet-no-save")
            return XCTFail("the save sheet had no Save button — tree above")
        }
        save.tap()

        // A second export over the same filename (any earlier run leaves one)
        // asks to replace. That alert is not always in the app's own tree, so
        // look in SpringBoard too, and wait for whichever comes first.
        let exported = app.staticTexts["Configuration exported"]
        let replaceButtons = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
            .map { $0.buttons["Replace"].firstMatch }
        let deadline = Date().addingTimeInterval(30)
        var confirmed = false
        while !confirmed, Date() < deadline {
            confirmed = exported.waitForExistence(timeout: 1)
            if !confirmed, let replace = replaceButtons.first(where: { $0.exists && $0.isHittable }) {
                attach("04-replace-existing")
                replace.tap()
            }
        }
        attach("04-after-save")
        XCTAssertTrue(confirmed, "the Backup screen never confirmed the export")
        attach("05-export-confirmed")

        // Import the file that was just written.
        let importButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Import Configuration")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 20), "no Import Configuration button")
        importButton.tap()
        Thread.sleep(forTimeInterval: 6)
        attach("06-browse-sheet")
        dump("browse-sheet")

        // The browse sheet reopens where the save sheet left off, so the file
        // is usually right there. Fall back to walking to it, then to search.
        var file = fileElement()
        if !file.exists {
            _ = tap(["Browse"])
            Thread.sleep(forTimeInterval: 2)
            _ = tap(["On My iPhone"])
            Thread.sleep(forTimeInterval: 2)
            _ = tap(["oStream"])
            Thread.sleep(forTimeInterval: 2)
            _ = tap(["Imports"])
            Thread.sleep(forTimeInterval: 2)
            attach("07-browse-walked")
            dump("browse-walked")
            file = fileElement()
        }
        if !file.exists, app.searchFields.firstMatch.exists {
            let search = app.searchFields.firstMatch
            search.tap()
            search.typeText("openstream-config")
            Thread.sleep(forTimeInterval: 4)
            attach("07b-browse-search")
            dump("browse-search")
            file = fileElement()
        }
        guard file.exists else {
            dump("browse-no-file")
            return XCTFail("openstream-config.json was not reachable in the browse sheet — trees above")
        }
        file.tap()
        Thread.sleep(forTimeInterval: 5)
        attach("08-import-review")

        // The review sheet is the observable proof the file parsed: it lists
        // the counts read out of it.
        let reviewTitle = app.staticTexts["Import Configuration"]
        XCTAssertTrue(reviewTitle.waitForExistence(timeout: 30), "the import review sheet never appeared")
        for row in ["Sources", "Playback progress", "My List", "Ratings"] {
            let cell = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", row)).firstMatch
            print("REVIEW \(row) → \(cell.exists ? cell.label : "absent")")
        }

        let confirm = app.buttons["Import"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the review sheet had no Import button")
        confirm.tap()
        Thread.sleep(forTimeInterval: 8)
        attach("09-after-import")

        let imported = app.staticTexts["Configuration imported"]
        XCTAssertTrue(imported.waitForExistence(timeout: 60), "the Backup screen never confirmed the import")
        attach("10-import-confirmed")
    }
}
