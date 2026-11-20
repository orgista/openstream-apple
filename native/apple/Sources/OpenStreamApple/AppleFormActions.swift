import SwiftUI

/// Where a settings form puts its action buttons (Add Catalog, Test
/// Connection, Save, Export…).
///
/// On the Mac a lone button in a form row sat inside a full-width grey bar —
/// "a small button in a big bar, looks odd" (owner, 2026-09-24). System
/// Settings puts them under the group instead: content-sized, at the trailing
/// edge, with no row behind them. Everywhere else the buttons keep the form's
/// own rows, as before.
public enum AppleFormActionLayout: Sendable, Equatable {
    /// Content-sized buttons, trailing, below the group, no row chrome.
    case trailingFooter
    /// The buttons sit in a row of the form, as the platform draws it.
    case formRow

    public static func layout(for platform: AppleUIPlatform) -> AppleFormActionLayout {
        platform == .macOS ? .trailingFooter : .formRow
    }

    public static var current: AppleFormActionLayout { layout(for: .current) }
}

/// The trailing row of content-sized buttons the Mac shows under a form group.
/// Put it in a `Section` footer so the buttons have no row chrome behind them.
struct AppleFormActionBar<Actions: View>: View {
    private let actions: Actions

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            actions
        }
        .controlSize(.regular)
    }
}

/// A form's action buttons as their own group: on the Mac an empty section
/// whose footer is an `AppleFormActionBar`; elsewhere an ordinary section with
/// the buttons in its rows (`AppleFormActionLayout`).
struct AppleFormActionSection<Actions: View>: View {
    private let actions: Actions

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        #if os(macOS)
        Section {
        } footer: {
            AppleFormActionBar { actions }
        }
        #else
        Section { actions }
        #endif
    }
}

extension View {
    /// The brand's primary button on the Mac, where form actions are
    /// free-standing buttons; untouched elsewhere, where the form row is the
    /// control.
    @ViewBuilder
    func appleMacFormPrimaryAction() -> some View {
        #if os(macOS)
        buttonStyle(.brandPrimary)
        #else
        self
        #endif
    }
}
