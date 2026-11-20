import Foundation

public struct AppleRestrictionPolicy: Codable, Equatable, Sendable {
    public var channelIDs: Set<String> = []
    public var groups: Set<String> = []
    public var lockSettings = false
    public var hideLocked = false
    public init() {}
    public static func validPIN(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    public func isLocked(channelID: String, group: String) -> Bool {
        channelIDs.contains(channelID) || groups.contains(group)
    }
    public func isVisible(channelID: String, group: String, hasPIN: Bool) -> Bool {
        !hasPIN || !hideLocked || !isLocked(channelID: channelID, group: group)
    }
}
