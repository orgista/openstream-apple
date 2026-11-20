import Testing
@testable import OpenStreamApple

/// Owner iPad 2026-10-28: picking a channel from Live search while a playlist reload
/// waited left the tab bar hidden.
@Suite("Live search exit")
struct AppleLiveSearchExitTests {
    @Test func anActiveFieldEndsBeforeThePagePops() {
        #expect(AppleLiveSearchExit.next(isShown: true, fieldPresented: true, isLeaving: false) == .endFieldFirst)
    }

    /// The field was never focused (or the user already ended it): nothing to wait for.
    @Test func aFieldThatIsNotActivePopsAtOnce() {
        #expect(AppleLiveSearchExit.next(isShown: true, fieldPresented: false, isLeaving: false) == .pop)
    }

    /// The pick and the start it causes both ask Search to leave; the second ask must
    /// not pop over the field's end, and the deadline still bounds the wait.
    @Test func aSecondRequestWhileLeavingWaitsForTheFirst() {
        #expect(AppleLiveSearchExit.next(isShown: true, fieldPresented: false, isLeaving: true) == nil)
        #expect(AppleLiveSearchExit.next(isShown: true, fieldPresented: true, isLeaving: true) == nil)
    }

    @Test func aHiddenPageHasNothingToLeave() {
        #expect(AppleLiveSearchExit.next(isShown: false, fieldPresented: true, isLeaving: false) == nil)
    }

    @Test func theFallbackOutlastsTheFieldCollapse() {
        #expect(AppleLiveSearchExit.deadline > AppleLiveSearchExit.fieldCollapse)
        #expect(AppleLiveSearchExit.deadline <= .seconds(1))
    }
}
