import Testing
@testable import OpenStreamApple

/// `submitLabel` and `onSubmit` appeared **zero** times across 25 `TextField`s,
/// so on a phone the return key said "return" and did nothing: the only way
/// through a four-field form was to dismiss the keyboard and tap the next
/// field.
@Suite("Keyboard field chain")
struct AppleFormFieldChainTests {
    private enum Field: Hashable { case name, endpoint, username, unlisted }

    private let xtream: [Field] = [.name, .endpoint, .username]
    private let plain: [Field] = [.name, .endpoint]

    @Test func theReturnKeyWalksTheFieldsInOrder() {
        #expect(AppleFormFieldChain.next(after: .name, in: xtream) == .endpoint)
        #expect(AppleFormFieldChain.next(after: .endpoint, in: xtream) == .username)
        #expect(AppleFormFieldChain.next(after: .username, in: xtream) == nil)
    }

    /// The form hides username unless the type is Xtream, so "the last field"
    /// moves. Endpoint is last in the plain form and not in the Xtream one.
    @Test func theLastFieldDependsOnWhatIsOnScreen() {
        #expect(AppleFormFieldChain.isLast(.endpoint, in: plain))
        #expect(!AppleFormFieldChain.isLast(.endpoint, in: xtream))
        #expect(AppleFormFieldChain.isLast(.username, in: xtream))
    }

    /// A field that is not on screen must read "done" rather than promise a
    /// next stop that cannot be focused.
    @Test func aFieldOutsideTheChainNeverPromisesANextStop() {
        #expect(AppleFormFieldChain.next(after: .unlisted, in: xtream) == nil)
        #expect(AppleFormFieldChain.isLast(.unlisted, in: xtream))
    }

    @Test func aSingleFieldFormIsImmediatelyDone() {
        let only: [Field] = [.name]
        #expect(AppleFormFieldChain.isLast(.name, in: only))
        #expect(AppleFormFieldChain.next(after: .name, in: only) == nil)
    }

    @Test func anEmptyChainIsSafe() {
        let empty: [Field] = []
        #expect(AppleFormFieldChain.next(after: .name, in: empty) == nil)
        #expect(AppleFormFieldChain.isLast(.name, in: empty))
    }

    /// Walking from the first field must reach every field exactly once and
    /// terminate — no cycles, nothing skipped.
    @Test func walkingTheChainVisitsEveryFieldAndStops() {
        var visited: [Field] = [.name]
        var cursor: Field? = .name
        while let current = cursor, visited.count <= xtream.count {
            cursor = AppleFormFieldChain.next(after: current, in: xtream)
            if let cursor { visited.append(cursor) }
        }
        #expect(visited == xtream)
    }
}
