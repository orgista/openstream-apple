import Foundation
import Testing
@testable import OpenStreamApple

/// The widget reported "Nothing in progress" whether the viewer had genuinely
/// finished everything or the app had never published a snapshot at all — which
/// on iPhone it never did, because the writers were `#if os(tvOS)`. Telling
/// someone with four half-watched shows that nothing is in progress is untrue,
/// and it hides the setting that would fix it.
@Suite("Widget empty state")
struct AppleWidgetEmptyStateTests {
    @Test func noSnapshotIsNotTheSameAsAnEmptyOne() {
        #expect(AppleWidgetEmptyState.state(hasSnapshot: false) == .notPublished)
        #expect(AppleWidgetEmptyState.state(hasSnapshot: true) == .nothingInProgress)
    }

    @Test func theTwoCasesNeverReadTheSame() {
        #expect(AppleWidgetEmptyState.notPublished.message
                != AppleWidgetEmptyState.nothingInProgress.message)
    }

    /// Both have to fit a small widget.
    @Test func bothMessagesAreShort() {
        for state in [AppleWidgetEmptyState.notPublished, .nothingInProgress] {
            #expect(!state.message.isEmpty)
            #expect(state.message.count <= 28, "\(state.message) is too long for a small widget")
        }
    }

    /// A reader pointed at a directory with no snapshot yields the state that
    /// sends the viewer to the setting, not the one that claims they are done.
    @Test func aReaderWithNoFileProducesTheNotPublishedState() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "widget-empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })
        #expect(reader.read() == nil)
        #expect(AppleWidgetEmptyState.state(hasSnapshot: reader.read() != nil) == .notPublished)
    }
}
