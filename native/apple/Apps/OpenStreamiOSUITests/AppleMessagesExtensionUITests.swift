import XCTest

/// Drives the real Messages app to prove the OpenStream iMessage extension
/// loads, lists what the app published into the shared app group, and composes
/// a real message bubble.
///
/// Nothing else can reach it: the extension has no host app of its own,
/// `simctl` cannot open the Messages send menu, and `Messages.framework` does
/// not exist on macOS, so `swift test` cannot touch it. What the extension
/// *decides* — which titles it offers and what the bubble says — is covered by
/// `AppleMessagesShareTests` in the package; this covers that it is installed,
/// discoverable, renders, and inserts.
///
/// The rows come from `topshelf-v1.json` in `group.com.orgista.openstream`,
/// which the app writes only while Continue Watching publishing is on under
/// Settings › Privacy. With no snapshot the extension draws its empty state,
/// and this test checks that instead of failing.
@MainActor
final class AppleMessagesExtensionUITests: OpenStreamUITestCase {
    private var messages: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    }

    override func tearDown() {
        messages?.terminate()
    }

    func testOpenStreamComposesAShareBubble() throws {
        messages.launch()

        // iOS 26 opens Messages behind a one-time notice about message
        // screening; the conversation list is not hittable until it is gone.
        let acknowledge = messages.buttons["OK"]
        if acknowledge.waitForExistence(timeout: 5) { acknowledge.tap() }

        // The list is a collection view whose cells nest a duplicate cell, and
        // neither reports itself hittable; a coordinate tap lands regardless.
        let list = messages.collectionViews["ConversationList"]
        let conversation = (list.exists ? list : messages).cells.firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 20), "no conversation to open")
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The conversation is open once the compose field is there.
        XCTAssertTrue(messages.textViews.firstMatch.waitForExistence(timeout: 10)
                      || messages.textFields.firstMatch.waitForExistence(timeout: 5),
                      "the conversation never opened")
        // "Apps" on iOS 18; the same control is unlabelled on iOS 26, where it
        // is the only button sitting left of the compose field.
        var apps = messages.buttons["Apps"]
        if !apps.waitForExistence(timeout: 8) {
            let leftOfCompose = NSPredicate { element, _ in
                guard let element = element as? XCUIElementAttributes else { return false }
                return element.frame.minX < 60 && element.frame.minY > 400
            }
            let candidate = messages.buttons.matching(leftOfCompose).firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 5),
                          "no Apps button: \(messages.buttons.allElementsBoundByIndex.map { "\($0.identifier)/\($0.label)" })")
            apps = candidate
        }
        apps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The send menu is a collection of app cells; wait for it rather than
        // for a clock.
        XCTAssertTrue(messages.cells.firstMatch.waitForExistence(timeout: 10), "the send menu never opened")

        // The send menu is a lazy collection view whose last rows sit below the
        // screen, so a third-party app is absent from the hierarchy until it
        // has been scrolled into view.
        let entry = messages.cells.matching(
            NSPredicate(format: "identifier CONTAINS %@", "com.orgista.openstream.messages")
        ).firstMatch
        for _ in 0..<5 where !entry.waitForExistence(timeout: 2) {
            messages.swipeUp()
        }
        XCTAssertTrue(entry.exists, "oStream is not listed in the Messages send menu")
        entry.tap()

        let row = messages.buttons["messages.share.row"].firstMatch
        guard row.waitForExistence(timeout: 10) else {
            // No snapshot published: the extension still has to have loaded and
            // drawn rather than crashed or come up blank.
            XCTAssertTrue(
                messages.otherElements["messages.share.empty"].exists,
                "the extension drew neither a row nor its empty state"
            )
            return
        }

        // The subcaption is a claim about the sender, so it has to match the
        // shelf the title came from.
        let label = row.label
        XCTAssertTrue(
            label.hasSuffix("Watching now") || label.hasSuffix("On oStream"),
            "unexpected row wording: \(label)"
        )
        let title = String(label.split(separator: ",").first ?? "")
        row.tap()

        // A staged MSMessage renders as a link in the compose field, and the
        // send button only appears once there is something to send. iOS 26
        // appends ", 1 image" to the label when the poster loaded, so this
        // matches on the caption and subcaption rather than the whole string.
        let staged = messages.links.matching(
            NSPredicate(format: "label BEGINSWITH %@", label)
        ).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 10), "no bubble was composed for \(title)")
        XCTAssertTrue(messages.buttons["sendButton"].exists, "composed bubble is not sendable")

        // Never leave the draft behind: this runs on the owner's simulator.
        let remove = messages.buttons["Remove app from message"]
        if remove.waitForExistence(timeout: 5) {
            remove.tap()
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: staged)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed,
                       "the composed bubble was left in the conversation")
    }
}
