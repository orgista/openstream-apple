import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases the happy-path suite (`AppleAudioRoutePolicyTests`) does not
/// cover: `nil` on both entry points, the two raw-value gaps AVFoundation
/// itself never assigns (5 and everything above 8), and consistency
/// between the typed `Reason` API and the raw-value one every notification
/// actually carries.
@Suite("Audio route policy edge cases")
struct AppleAudioRoutePolicyEdgeTests {
    @Test func resumingIsRefusedEvenWithNoReasonAtAll() {
        #expect(!AppleAudioRoutePolicy.shouldResume(for: nil))
    }

    @Test func rawValueNilBehavesLikeReasonNil() {
        #expect(AppleAudioRoutePolicy.shouldPause(forRawValue: nil)
                == AppleAudioRoutePolicy.shouldPause(for: nil))
        #expect(!AppleAudioRoutePolicy.shouldPause(forRawValue: nil))
    }

    /// Every defined reason must give the same answer whether it arrives as
    /// a typed `Reason` or as the raw value the notification actually
    /// carries; the two entry points must never disagree.
    @Test("Raw-value lookup matches the typed reason", arguments: AppleAudioRoutePolicy.Reason.allCases)
    func rawValueLookupMatchesTypedReason(_ reason: AppleAudioRoutePolicy.Reason) {
        #expect(AppleAudioRoutePolicy.shouldPause(forRawValue: reason.rawValue)
                == AppleAudioRoutePolicy.shouldPause(for: reason))
    }

    /// Raw value 5 sits in the gap AVFoundation itself never assigns
    /// (unknown=0 … routeConfigurationChange=8, skipping 5); it must decode
    /// to no reason rather than silently aliasing a neighbouring case.
    @Test func theUnassignedRawValueFiveDecodesToNoReason() {
        #expect(AppleAudioRoutePolicy.Reason(rawValue: 5) == nil)
        #expect(!AppleAudioRoutePolicy.shouldPause(forRawValue: 5))
    }

    @Test("Out-of-range raw values never pause", arguments: [UInt(9), UInt(100), UInt.max])
    func outOfRangeRawValuesNeverPause(_ raw: UInt) {
        #expect(AppleAudioRoutePolicy.Reason(rawValue: raw) == nil)
        #expect(!AppleAudioRoutePolicy.shouldPause(forRawValue: raw))
    }

    /// Guards the reason list itself: an accidental addition, removal, or
    /// renumbering of a case would silently change which route changes
    /// pause playback.
    @Test func reasonCasesAreExactlyTheEightDefinedValues() {
        #expect(AppleAudioRoutePolicy.Reason.allCases.count == 8)
        #expect(Set(AppleAudioRoutePolicy.Reason.allCases.map(\.rawValue))
                == Set<UInt>([0, 1, 2, 3, 4, 6, 7, 8]))
    }
}
