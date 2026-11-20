import SwiftUI

#if os(tvOS)
/// A settings choice on Apple TV: a row showing the current value that pushes
/// a page of the options, each with a check, as the stock Settings app does.
///
/// A stock `Picker` in these forms pushed an empty page, and Menu on it left
/// the app for the Home screen (Settings › Channel Manager › Package, Live
/// view, Playback › Player; Apple TV verification 2026-10-01). This pushes
/// an ordinary page the app owns, so it draws its rows and Menu pops it.
struct AppleTVChoicePicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]

    init(_ title: String, selection: Binding<Value>, options: [Option]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        NavigationLink {
            AppleTVChoicePage(title: title, selection: $selection, options: options)
        } label: {
            AppleTVChoiceRowLabel(title: title, value: currentTitle)
        }
        .accessibilityValue(currentTitle)
    }
}

/// Title on the leading edge, value on the trailing; black on the white
/// focus platter, so neither disappears into it.
private struct AppleTVChoiceRowLabel: View {
    let title: String
    let value: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(isFocused ? Color.black : Color.white)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppleTVChoicePage<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AppleTVChoicePicker<Value>.Option]
    @Environment(\.dismiss) private var dismiss
    /// The page opens on the checked option, as the stock Settings app does
    /// (Show Captions opened on "Off" whatever was checked, Apple TV
    /// regression 2026-10-01).
    @FocusState private var focusedValue: Value?

    var body: some View {
        Form {
            ForEach(options) { option in
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    AppleTVChoiceOptionLabel(title: option.title, isSelected: option.value == selection)
                }
                .focused($focusedValue, equals: option.value)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .defaultFocus($focusedValue, selection)
        .appleSettingsPage(title)
        .tint(.white)
        // One level back, never out of the app: the tab's own handler pops
        // value routes only, and this page is not one.
        .onExitCommand { dismiss() }
    }
}

private struct AppleTVChoiceOptionLabel: View {
    let title: String
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            if isSelected {
                Image(systemName: "checkmark")
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}
#endif
