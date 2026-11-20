import Foundation

public struct AppleProgrammeReminder: Identifiable, Codable, Equatable, Sendable {
    public let channelID: String
    public let channelName: String
    public let title: String
    public let start: Date
    public let end: Date
    public var id: String { ApplePlaybackIdentity.digest(for: channelID + "|" + String(start.timeIntervalSince1970)) }

    public init(channelID: String, channelName: String, title: String, start: Date, end: Date) {
        self.channelID = channelID
        self.channelName = channelName
        self.title = title
        self.start = start
        self.end = end
    }
    public func isDue(at now: Date) -> Bool { start <= now && now < end && now.timeIntervalSince(start) <= 300 }
}
