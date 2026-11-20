import SwiftUI

struct AppleSettingsPicker<Value: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        #if os(tvOS)
        LabeledContent(title) {
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .pickerStyle(.menu)
        }
        .focusSection()
        #else
        Picker(title, selection: $selection) { content }
        #endif
    }
}
