import Foundation
import Testing
@testable import OpenStreamApple

/// Owner B17: channel numbers must not be grouped — "1001", not "1,001". The
/// guide grid used `.number`, which applies the locale's thousands separator,
/// while the rail label interpolated the same value and did not. The same
/// channel was written two ways on one screen.
@Suite("Channel number format")
struct AppleChannelNumberFormatTests {
    @Test func aFourDigitChannelCarriesNoSeparator() {
        #expect(AppleChannelNumberFormat.string(1001) == "1001")
        #expect(AppleChannelNumberFormat.string(1234) == "1234")
    }

    @Test func aFiveDigitChannelCarriesNoSeparator() {
        #expect(AppleChannelNumberFormat.string(10203) == "10203")
    }

    @Test func shortChannelsAreUnchanged() {
        #expect(AppleChannelNumberFormat.string(2) == "2")
        #expect(AppleChannelNumberFormat.string(999) == "999")
    }

    /// The point of the fix: it must differ from the plain numeric style in a
    /// grouping locale, otherwise nothing was actually corrected.
    @Test func itDiffersFromTheGroupedStyleItReplaced() {
        let grouped = 1001.formatted(IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US")))
        let ours = 1001.formatted(AppleChannelNumberFormat.style.locale(Locale(identifier: "en_US")))
        #expect(grouped == "1,001")
        #expect(ours == "1001")
    }

    /// And it must stay ungrouped in a locale that groups differently.
    @Test func itStaysUngroupedInOtherLocales() {
        for identifier in ["de_DE", "fr_FR", "en_GB", "hi_IN"] {
            let value = 10203.formatted(
                AppleChannelNumberFormat.style.locale(Locale(identifier: identifier)))
            #expect(value == "10203", "\(identifier) rendered \(value)")
        }
    }

    /// Matches what the rail label produces by interpolation, so the two
    /// renderings of one channel cannot drift apart again.
    @Test func itMatchesPlainInterpolation() {
        for number in [2, 99, 1001, 10203] {
            #expect(AppleChannelNumberFormat.string(number) == "\(number)")
        }
    }
}
