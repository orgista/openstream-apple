import Foundation

public enum AppleSleepTimerPolicy {
    public static let minuteOptions = [15, 30, 45, 60, 90, 120]

    public static func deadline(minutes: Int, now: Date = .now) -> Date? {
        #if DEBUG
        let allowed = minuteOptions + [1]
        #else
        let allowed = minuteOptions
        #endif
        guard allowed.contains(minutes) else { return nil }
        return now.addingTimeInterval(Double(minutes) * 60)
    }

    public static func programmeDeadline(end: Date?, now: Date = .now) -> Date? {
        guard let end, end > now else { return nil }
        return end
    }
}
