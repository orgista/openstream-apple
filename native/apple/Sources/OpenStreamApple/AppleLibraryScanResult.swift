import Foundation

public enum AppleLibraryScanStatus: String, Codable, Sendable {
    case complete, partial, failed
}

public struct AppleLibraryScanResult: Sendable {
    public let items: [AppleLibraryItem]
    public let status: AppleLibraryScanStatus
    /// Why a network share's scan failed, when it got as far as the server.
    public let shareFailure: AppleSMBError?

    public init(items: [AppleLibraryItem], status: AppleLibraryScanStatus, shareFailure: AppleSMBError? = nil) {
        self.items = items
        self.status = status
        self.shareFailure = shareFailure
    }

    public func retaining(_ previous: [AppleLibraryItem]) -> [AppleLibraryItem] {
        guard status != .complete else { return items }
        return Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .merging(Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })) { _, new in new }
            .values.sorted { $0.relativePath < $1.relativePath }
    }
}
