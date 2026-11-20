import Testing
@testable import OpenStreamApple

@Suite struct AppleShelfFocusTests {
    @Test func reentryRestoresMemoryBeforeTheGeometricChoiceCanReplaceIt() {
        var memory = AppleShelfFocusMemory()
        let ids = ["first", "second", "third"]
        #expect(memory.update(from: nil, to: "third", availableIDs: ids) == "first")
        #expect(memory.update(from: "first", to: "second", availableIDs: ids) == "second")
        #expect(memory.update(from: "second", to: nil, availableIDs: ids) == nil)
        #expect(memory.update(from: nil, to: "third", availableIDs: ids) == "second")
        #expect(memory.preferredID(in: ids) == "second")
    }

    @Test func blurPreservesTheLastTileAndReorderingKeepsItsIdentity() {
        var memory = AppleShelfFocusMemory()
        #expect(memory.preferredID(in: ["first", "second"]) == "first")
        memory.remember("second")
        memory.remember(nil)
        #expect(memory.preferredID(in: ["second", "first"]) == "second")
    }

    @Test func removedTilesFallBackToTheFirstAvailableTile() {
        var memory = AppleShelfFocusMemory()
        memory.remember("removed")
        #expect(memory.preferredID(in: ["new", "other"]) == "new")
        #expect(memory.preferredID(in: []) == nil)
    }
}
