import Testing
@testable import OpenStreamApple

@Suite struct AppleTrailerKeyFallbackPolicyTests {
    typealias Policy = AppleTrailerKeyFallbackPolicy

    @Test(arguments: [100, 101, 150])
    func aBlockedOrMissingVideoMovesToTheNextKey(code: Int) {
        #expect(Policy.nextKeyIndex(after: 0, errorCode: code, keyCount: 3) == 1)
        #expect(Policy.nextKeyIndex(after: 1, errorCode: code, keyCount: 3) == 2)
    }

    @Test(arguments: [100, 101, 150])
    func theLastKeyGivesUp(code: Int) {
        #expect(Policy.nextKeyIndex(after: 2, errorCode: code, keyCount: 3) == nil)
        #expect(Policy.nextKeyIndex(after: 0, errorCode: code, keyCount: 1) == nil)
    }

    @Test(arguments: [2, 5, 153] as [Int?] + [nil])
    func otherErrorsDoNotMoveOn(code: Int?) {
        #expect(Policy.nextKeyIndex(after: 0, errorCode: code, keyCount: 3) == nil)
    }

    @Test func everyKeyIsTriedOnceInOrder() {
        var tried = [0]
        while let next = Policy.nextKeyIndex(after: tried.last!, errorCode: 150, keyCount: 4) {
            tried.append(next)
        }
        #expect(tried == [0, 1, 2, 3])
    }

    @Test func aPressedKeyComesFirstAndNoKeyRepeats() {
        #expect(Policy.orderedKeys(preferred: "b", keys: ["a", "b", "c", "a"]) == ["b", "a", "c"])
        #expect(Policy.orderedKeys(preferred: nil, keys: ["a", "", "c"]) == ["a", "c"])
    }
}
