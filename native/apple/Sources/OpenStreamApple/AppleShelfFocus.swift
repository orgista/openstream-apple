import SwiftUI

struct AppleShelfFocusMemory: Equatable {
    private var lastID: String?

    mutating func remember(_ id: String?) {
        if let id { lastID = id }
    }

    func preferredID(in ids: [String]) -> String? {
        lastID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    mutating func update(from oldID: String?, to newID: String?, availableIDs: [String]) -> String? {
        guard let newID else { return nil }
        let target = oldID == nil ? preferredID(in: availableIDs) ?? newID : newID
        remember(target)
        return target
    }
}

#if os(tvOS)
struct AppleShelfFocus: Equatable {
    let selection: FocusState<String?>.Binding
    let preferredID: String?
    let namespace: Namespace.ID

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Each namespace owns one selection binding across body updates.
        lhs.namespace == rhs.namespace && lhs.preferredID == rhs.preferredID
    }
}

extension EnvironmentValues {
    @Entry var appleShelfFocus: AppleShelfFocus? = nil
}

private struct AppleShelfFocusItem: ViewModifier {
    let id: String
    @Environment(\.appleShelfFocus) private var shelf

    @ViewBuilder func body(content: Content) -> some View {
        if let shelf {
            content
                .focused(shelf.selection, equals: id)
                .prefersDefaultFocus(shelf.preferredID == id, in: shelf.namespace)
        } else {
            content
        }
    }
}
#endif

extension View {
    @ViewBuilder func appleShelfFocusItem(id: String) -> some View {
        #if os(tvOS)
        modifier(AppleShelfFocusItem(id: id))
        #else
        self
        #endif
    }
}
