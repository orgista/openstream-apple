import SwiftUI

struct AppleLibraryPoster: Equatable, Sendable {
    let groupID: String
    let url: URL
}

private struct AppleLibraryPosterKey: EnvironmentKey {
    static let defaultValue: AppleLibraryPoster? = nil
}

extension EnvironmentValues {
    var appleLibraryPoster: AppleLibraryPoster? {
        get { self[AppleLibraryPosterKey.self] }
        set { self[AppleLibraryPosterKey.self] = newValue }
    }
}
