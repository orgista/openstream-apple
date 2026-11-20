import SwiftUI

private struct AppleLibraryFixMatchActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

private struct AppleLibraryAutomaticMatchActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

private struct AppleLibraryIsMatchedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appleLibraryFixMatch: (@MainActor () -> Void)? {
        get { self[AppleLibraryFixMatchActionKey.self] }
        set { self[AppleLibraryFixMatchActionKey.self] = newValue }
    }

    /// Set only while the title carries a manual correction.
    var appleLibraryAutomaticMatch: (@MainActor () -> Void)? {
        get { self[AppleLibraryAutomaticMatchActionKey.self] }
        set { self[AppleLibraryAutomaticMatchActionKey.self] = newValue }
    }

    var appleLibraryIsMatched: Bool {
        get { self[AppleLibraryIsMatchedKey.self] }
        set { self[AppleLibraryIsMatchedKey.self] = newValue }
    }
}

struct AppleLibraryFixMatchMenuAction: View {
    @Environment(\.appleLibraryFixMatch) private var fixMatch
    @Environment(\.appleLibraryAutomaticMatch) private var automaticMatch
    @Environment(\.appleLibraryIsMatched) private var isMatched

    var body: some View {
        if let fixMatch {
            Button(isMatched ? "Change Metadata" : "Match", systemImage: "pencil", action: fixMatch)
                .accessibilityIdentifier("detail.fixMatch")
        }
        if let automaticMatch {
            Button("Use Automatic Match", systemImage: "arrow.uturn.backward", action: automaticMatch)
                .accessibilityIdentifier("detail.automaticMatch")
        }
    }
}
