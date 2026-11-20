import SwiftUI

struct AppleIPTVAccountSection: View {
    let source: AppleSource
    let sourceStore: AppleSourceStore
    @State private var info: AppleIPTVAccountInfo?
    @State private var error: String?

    var body: some View {
        Section("Account") {
            if let info {
                if let status = info.status { LabeledContent("Status", value: status) }
                if let expiry = info.expiresAt {
                    LabeledContent("Expires on", value: expiry.formatted(date: .abbreviated, time: .omitted))
                }
                if let usage = info.streamsInUse { Text(usage) }
            } else if let error { Text(error) }
            else { ProgressView() }
        }
        .task(id: source.id) {
            do {
                guard let credentials = try sourceStore.iptvCredentials(for: source) else {
                    error = AppleIPTVError.missingCredentials.localizedDescription
                    return
                }
                let result = try await AppleIPTVClient().accountInfo(source: source, credentials: credentials)
                guard !Task.isCancelled else { return }
                info = result
                error = nil
            } catch is CancellationError { }
            catch { self.error = AppleDiagnosticRedactor.redact(error.localizedDescription) }
        }
        .accessibilityIdentifier("source.account")
    }
}
