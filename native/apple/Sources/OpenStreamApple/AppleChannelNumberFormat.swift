import Foundation

/// How a channel number is written.
///
/// A channel number is an identifier, not a quantity, so it never carries a
/// thousands separator: channel 1001 is "1001", not "1,001". The guide used
/// `.number` in one place and string interpolation in another, so the same
/// channel was written two different ways on the same screen depending on which
/// view drew it (owner B17).
public enum AppleChannelNumberFormat {
    /// For `Text(number, format:)`.
    public static let style = IntegerFormatStyle<Int>.number.grouping(.never)

    /// For anywhere a string is needed instead.
    public static func string(_ number: Int) -> String {
        number.formatted(style)
    }
}
