#if DEBUG
import SwiftUI

public struct AppleOfflineDownloadDebugView: View {
    @State private var coordinator: AppleOfflineDownloadCoordinator
    private let fixtureURL: URL?

    public init() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-download-ui-fixture", directoryHint: .isDirectory)
        let store = AppleOfflineMediaStore(
            rootDirectory: root.appending(path: "library", directoryHint: .isDirectory),
            allowedDirectories: [root, FileManager.default.temporaryDirectory]
        )
        _coordinator = State(initialValue: AppleOfflineDownloadCoordinator(
            store: store,
            temporaryDirectory: root.appending(path: "partials", directoryHint: .isDirectory)
        ))
        fixtureURL = ProcessInfo.processInfo.environment["OPENSTREAM_DOWNLOAD_FIXTURE_URL"].flatMap(URL.init(string:))
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Sample Movie")
                    .font(.largeTitle.bold())
                Text("OpenStream Offline Storage")
                    .foregroundStyle(.secondary)
                status
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
            .foregroundStyle(.white)
            .navigationTitle("Download Verification")
        }
        .task {
            guard case .idle = coordinator.state, let fixtureURL else { return }
            coordinator.start(
                request: .init(
                    mediaID: "movie:download-ui-fixture",
                    itemTitle: "Sample Movie",
                    subtitle: "Local fixture",
                    artworkURL: nil,
                    destinationLabel: "OpenStream Offline Storage"
                ),
                plans: [.init(sourceURL: fixtureURL, requestHeaders: [:], protectedCapabilityToRevoke: nil)]
            )
        }
    }

    @ViewBuilder
    private var status: some View {
        switch coordinator.state {
        case .idle:
            Text("Waiting")
        case .resolving:
            ProgressView("Preparing Sample Movie")
                .accessibilityIdentifier("fixture.download.resolving")
        case .downloading(_, _, let received, let expected):
            progress(received: received, expected: expected, label: "Downloading")
            HStack {
                Button("Pause") { coordinator.pause() }
                    .accessibilityIdentifier("fixture.download.pause")
                Button("Cancel", role: .destructive) { coordinator.cancel() }
                    .accessibilityIdentifier("fixture.download.cancel")
            }
        case .paused(_, _, let received, let expected):
            progress(received: received, expected: expected, label: "Paused")
            HStack {
                Button("Resume") { coordinator.resume() }
                    .accessibilityIdentifier("fixture.download.resume")
                Button("Cancel", role: .destructive) { coordinator.cancel() }
                    .accessibilityIdentifier("fixture.download.cancel")
            }
        case .resuming(_, _, let received, let expected):
            progress(received: received, expected: expected, label: "Resuming")
        case .completed(_, let destination, let bytes, _):
            Label("Download complete", systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture.download.completed")
            Text("\(byteLabel(bytes)) saved to OpenStream Offline Storage")
            Text(destination.lastPathComponent)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        case .failed(_, let message):
            Label("Download failed", systemImage: "exclamationmark.triangle.fill")
            Text(message)
            Button("Retry") { coordinator.retry() }
                .accessibilityIdentifier("fixture.download.retry")
        case .cancelled:
            Text("Download cancelled")
            Button("Retry") { coordinator.retry() }
                .accessibilityIdentifier("fixture.download.retry")
        }
    }

    @ViewBuilder
    private func progress(received: Int64, expected: Int64?, label: String) -> some View {
        Text(label)
            .font(.title2.bold())
            .accessibilityIdentifier("fixture.download.status")
        if let expected, expected > 0 {
            ProgressView(value: Double(received), total: Double(expected))
                .tint(.white)
        } else {
            ProgressView().tint(.white)
        }
        Text("\(byteLabel(received)) of \(expected.map(byteLabel) ?? "unknown size")")
            .monospacedDigit()
            .accessibilityIdentifier("fixture.download.bytes")
    }

    private func byteLabel(_ count: Int64) -> String {
        AppleByteFormatting.string(count)
    }
}
#endif
