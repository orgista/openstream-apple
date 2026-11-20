import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Live programme progress line")
struct AppleLiveProgrammeProgressTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func fractionRunsFromStartToEnd() {
        let end = start.addingTimeInterval(3600)
        #expect(AppleLiveProgrammeProgress.fraction(start: start, end: end, now: start) == 0)
        #expect(AppleLiveProgrammeProgress.fraction(start: start, end: end, now: start.addingTimeInterval(900)) == 0.25)
        #expect(AppleLiveProgrammeProgress.fraction(start: start, end: end, now: end.addingTimeInterval(60)) == 1)
        #expect(AppleLiveProgrammeProgress.fraction(start: start, end: end, now: start.addingTimeInterval(-60)) == 0)
    }

    @Test func noLengthNoLine() {
        #expect(AppleLiveProgrammeProgress.fraction(start: start, end: start, now: start) == nil)
    }
}
