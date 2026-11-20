import SwiftUI

/// How far through its programme a channel is, 0…1, or nil without one.
enum AppleLiveProgrammeProgress {
    static func fraction(start: Date, end: Date, now: Date) -> Double? {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / length))
    }
}

/// Keep the track's height stable while programme metadata arrives.
struct AppleLiveProgrammeLine: View {
    let programme: AppleIPTVProgramme?
    var lineHeight: CGFloat = 2
    var accessibilityID = "live.programmeProgress"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let fraction = programme.flatMap {
                AppleLiveProgrammeProgress.fraction(start: $0.start, end: $0.end, now: context.date)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.15))
                    if let fraction {
                        Rectangle().fill(.white.opacity(0.7))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
            }
            .frame(height: lineHeight)
            .accessibilityElement()
            .accessibilityLabel(programme?.title ?? "")
            .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
            .accessibilityHidden(programme == nil)
            .accessibilityIdentifier(accessibilityID)
        }
    }
}
