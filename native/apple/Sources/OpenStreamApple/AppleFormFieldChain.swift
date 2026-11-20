import Foundation
import SwiftUI

/// Moving between text fields from the keyboard.
///
/// Every field in the app shipped with the stock return key: `submitLabel` and
/// `onSubmit` appeared **zero** times across 25 `TextField`s. On a phone that
/// means the return key says "return", does nothing, and the only way through a
/// four-field form is to dismiss the keyboard and tap the next field.
///
/// The chain is computed from the fields actually on screen, because forms hide
/// fields — Add Live TV only shows username when the type is Xtream, so
/// "the last field" is not a fixed thing.
public enum AppleFormFieldChain {
    /// The field after `field`, or nil when it is the last one on screen.
    public static func next<Field: Equatable>(after field: Field, in order: [Field]) -> Field? {
        guard let index = order.firstIndex(of: field), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    /// Whether the return key should read "done" rather than "next".
    ///
    /// True for the last field and for anything not in the chain at all, so an
    /// unchained field never promises a next stop it cannot deliver.
    public static func isLast<Field: Equatable>(_ field: Field, in order: [Field]) -> Bool {
        next(after: field, in: order) == nil
    }
}

/// Wires one field into the keyboard's return key.
///
/// Applied at the call site rather than inside a shared field property, so
/// Apple TV — which has no software return key to label and drives focus with
/// the remote — is untouched.
struct AppleFormFieldSubmit<Field: Hashable>: ViewModifier {
    let field: Field
    let chain: [Field]
    let focus: FocusState<Field?>.Binding

    func body(content: Content) -> some View {
        #if os(iOS) || os(visionOS)
        content
            .focused(focus, equals: field)
            .submitLabel(AppleFormFieldChain.isLast(field, in: chain) ? .done : .next)
            .onSubmit {
                focus.wrappedValue = AppleFormFieldChain.next(after: field, in: chain)
            }
        #else
        // A no-op on Apple TV. There is no software return key to label, and
        // the tvOS form bodies already bind these very fields to their own
        // `@FocusState` for the remote — binding them a second time here left
        // two focus states competing over one field, and the tab bar drew its
        // selection pill without the gear and overflowing the bar.
        content
        #endif
    }
}

extension View {
    /// Makes the return key move to the next field, and read "done" on the last.
    func appleFormSubmit<Field: Hashable>(
        _ field: Field,
        chain: [Field],
        focus: FocusState<Field?>.Binding
    ) -> some View {
        modifier(AppleFormFieldSubmit(field: field, chain: chain, focus: focus))
    }
}
