import Foundation

public struct AppleGuideProgrammeSpan: Equatable, Sendable, Identifiable {
    public let id: String
    public let startOffset: Double
    public let width: Double
    public let title: String
    public let subtitle: String?
    public let isNow: Bool
    /// The programme's own times (nil for a "No information" gap).
    public let airStart: Date?
    public let airEnd: Date?
    /// Already aired and playable from the channel's archive
    /// (`AppleIPTVCatchUp.isAvailable`).
    public let isCatchUp: Bool

    public init(id: String, startOffset: Double, width: Double, title: String, subtitle: String?, isNow: Bool,
                airStart: Date? = nil, airEnd: Date? = nil, isCatchUp: Bool = false) {
        self.id = id
        self.startOffset = startOffset
        self.width = width
        self.title = title
        self.subtitle = subtitle
        self.isNow = isNow
        self.airStart = airStart
        self.airEnd = airEnd
        self.isCatchUp = isCatchUp
    }
}

public struct AppleGuideRowModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let channel: AppleIPTVChannel
    public let number: Int?
    public let spans: [AppleGuideProgrammeSpan]

    public init(id: String, channel: AppleIPTVChannel, number: Int?, spans: [AppleGuideProgrammeSpan]) {
        self.id = id
        self.channel = channel
        self.number = number
        self.spans = spans
    }
}
