import SwiftUI

struct AppleImportProgressView: View {
    private let store = AppleImportStore.shared
    #if os(tvOS)
    @FocusState private var focusedImport: UUID?
    #endif
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(store.operations) { operation in
                HStack {
                    VStack(alignment: .leading) {
                        Text(operation.title).font(.headline)
                            .accessibilityIdentifier("import.progress")
                        Text(operation.progress.phase == .downloading ? "Downloading" : "Importing").font(.caption)
                        Text("\(operation.progress.items) \(operation.unit) · \(ByteCountFormatter.string(fromByteCount: Int64(operation.progress.bytes), countStyle: .file))")
                            .monospacedDigit()
                        if operation.progress.totalBytes > 0 {
                            ProgressView(value: Double(operation.progress.bytes), total: Double(operation.progress.totalBytes))
                        } else {
                            ProgressView()
                        }
                    }
                    Button(action: operation.cancel) {
                        Text("Cancel").frame(minHeight: 44).contentShape(.rect)
                    }
                    .accessibilityIdentifier("import.cancel")
                    #if os(tvOS)
                    .focused($focusedImport, equals: operation.id)
                    #endif
                }
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
        #if os(tvOS)
        .focusSection()
        .task(id: store.operations.map(\.id)) {
            // Brief imports should not move focus. Longer imports offer Cancel first,
            // including when the player normally consumes directional remote input.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            if !Task.isCancelled { focusedImport = store.operations.first?.id }
        }
        #endif
    }
}
