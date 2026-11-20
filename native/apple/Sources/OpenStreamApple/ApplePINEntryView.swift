import SwiftUI

struct ApplePINEntryView: View {
    let title: String
    var error: String?
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void
    @State private var digits = ""
    @FocusState private var focus: Int?

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.title2)
            Text(String(repeating: "●", count: digits.count) + String(repeating: "○", count: 4 - digits.count))
                .font(.title).monospaced()
                .accessibilityLabel("PIN")
                .accessibilityValue("\(digits.count) of 4 digits entered")
                .accessibilityIdentifier("restrictions.pin")
            if let error { Text(error).accessibilityIdentifier("restrictions.pin.error") }
            Grid(horizontalSpacing: 24, verticalSpacing: 16) {
                ForEach(0..<3) { row in
                    GridRow {
                        ForEach(1..<4) { column in
                            digitButton(row * 3 + column)
                        }
                    }
                }
                GridRow {
                    Button("Delete", systemImage: "delete.left") { if !digits.isEmpty { digits.removeLast() } }
                        .accessibilityIdentifier("restrictions.pin.delete")
                        #if os(tvOS)
                        .labelStyle(.iconOnly)
                        #endif
                    digitButton(0)
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("restrictions.pin.cancel")
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if !os(tvOS)
        .tint(.primary)
        #endif
        .padding(32)
        .frame(maxWidth: 600)
        #if os(tvOS)
        .defaultFocus($focus, 1)
        .onAppear { focus = 1 }
        .onExitCommand(perform: onCancel)
        #endif
    }

    private func digitButton(_ digit: Int) -> some View {
        Button { enter(digit) } label: {
            Text(String(digit))
                .font(.title2)
                .frame(minWidth: 64, minHeight: 48)
                .contentShape(.rect)
        }
            .focused($focus, equals: digit)
            .accessibilityIdentifier("restrictions.pin.\(digit)")
    }
    private func enter(_ digit: Int) {
        guard digits.count < 4 else { return }
        digits += String(digit)
        if digits.count == 4 {
            _ = onSubmit(digits)
            digits = ""
        }
    }
}
