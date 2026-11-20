import SwiftUI

struct AppleHomeRowContext: Equatable {
    let row: AppleHomeRowSetting
    let settings: AppleSettingsStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let shelfIDs: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.shelfIDs == rhs.shelfIDs
            && lhs.settings === rhs.settings && lhs.mediaServerLibrary === rhs.mediaServerLibrary
    }

    @MainActor func refresh() async {
        for id in shelfIDs { await mediaServerLibrary.refresh(shelfID: id) }
    }
}

extension EnvironmentValues {
    @Entry var appleHomeRowContext: AppleHomeRowContext? = nil
}

struct AppleHomeRowContextMenu: ViewModifier {
    @Environment(\.appleHomeRowContext) private var context
    @State private var showsRename = false
    @State private var name = ""

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if let context {
            content
                .accessibilityIdentifier("home.row.heading.\(context.row.id)")
                .contextMenu {
                    Button("Rename...", systemImage: "pencil") {
                        name = context.row.title(in: context.settings)
                        showsRename = true
                    }
                    Button("Hide Row", systemImage: "eye.slash") {
                        context.row.setShown(false, in: context.settings)
                    }
                    if !context.shelfIDs.isEmpty {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await context.refresh() }
                        }
                    }
                }
                .alert("Rename Row", isPresented: $showsRename) {
                    TextField("Name", text: $name, prompt: Text(context.row.defaultName))
                    Button("Save") { context.row.setName(name, in: context.settings) }
                    Button("Cancel", role: .cancel) { }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
