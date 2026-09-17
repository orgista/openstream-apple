import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What a download's Live Activity shows, derived from the coordinator's state.
///
/// Plain data so the mapping can be asserted without ActivityKit, which only
/// exists on iOS — the same reason `AppleTopShelfSection` mirrors the Top Shelf
/// provider's sections.
public struct AppleDownloadActivityState: Codable, Hashable, Sendable {
    public let statusText: String
    /// `0...1`, or nil when the total size is not known yet — a Live Activity
    /// then shows an indeterminate bar rather than a lie.
    public let fractionComplete: Double?
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    /// Finished, failed or cancelled: the activity should end.
    public let isFinal: Bool

    public init(
        statusText: String,
        fractionComplete: Double?,
        receivedBytes: Int64,
        expectedBytes: Int64?,
        isFinal: Bool
    ) {
        self.statusText = statusText
        self.fractionComplete = fractionComplete
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.isFinal = isFinal
    }

    /// "1.2 GB of 4.5 GB", or just what has arrived when the total is unknown.
    public var byteSummary: String {
        let received = AppleByteFormatting.string(receivedBytes)
        guard let expectedBytes, expectedBytes > 0 else { return received }
        return "\(received) of \(AppleByteFormatting.string(expectedBytes))"
    }
}

/// Maps the download coordinator's state onto the activity, in one place so the
/// lock screen, the Dynamic Island and the in-app row cannot disagree.
public enum AppleDownloadActivityPresentation: Sendable {
    public static func state(
        received: Int64,
        expected: Int64?,
        status: Status
    ) -> AppleDownloadActivityState {
        AppleDownloadActivityState(
            statusText: status.text,
            fractionComplete: fraction(received: received, expected: expected, status: status),
            receivedBytes: received,
            expectedBytes: expected,
            isFinal: status.isFinal
        )
    }

    public enum Status: Equatable, Sendable {
        case resolving
        case downloading
        case paused
        case resuming
        case completed
        case failed(String)
        case cancelled

        var text: String {
            switch self {
            case .resolving: "Preparing"
            case .downloading: "Downloading"
            case .paused: "Paused"
            case .resuming: "Resuming"
            case .completed: "Downloaded"
            case .failed(let message): message
            case .cancelled: "Cancelled"
            }
        }

        var isFinal: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .resolving, .downloading, .paused, .resuming: false
            }
        }
    }

    /// A finished download reads 100% whatever the byte counts say; an unknown
    /// total reads as nil so the bar stays indeterminate rather than pretending
    /// to a precision it does not have.
    static func fraction(received: Int64, expected: Int64?, status: Status) -> Double? {
        if case .completed = status { return 1 }
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The Live Activity's shape. Lives in the shared package so the app and the
/// widget extension — separate processes — agree on it by construction.
public struct AppleDownloadActivityAttributes: ActivityAttributes {
    public typealias ContentState = AppleDownloadActivityState

    public let title: String
    public let subtitle: String?
    public let destination: String

    public init(title: String, subtitle: String?, destination: String) {
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
    }
}
#endif
