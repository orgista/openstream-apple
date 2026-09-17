#if os(iOS)
import SwiftUI

@MainActor
struct AppleLibraryTVView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue = AppleLibraryTVQueue()
    @State private var activeProgram: AppleLibraryTVProgram?
    @State private var access: AppleSecurityScopedAccess?
    @State private var coordinator = ApplePlaybackCoordinator()
    @State private var playbackRevision = 0
    @State private var notices: [String] = []
    @State private var isLoading = true
    @State private var reloadGeneration = 0
    private let builder = AppleLibraryTVBuilder()

    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading, queue.channels.isEmpty {
                    ProgressView("Loading Library TV…")
                } else if queue.channels.isEmpty {
                    ContentUnavailableView {
                        Label("Library TV", systemImage: "play.rectangle.on.rectangle")
                    } description: {
                        ForEach(notices, id: \.self) { Text($0) }
                    } actions: {
                        Button("Open Settings") { dismiss(); openSettings() }
                            .buttonStyle(.brandPrimary)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let program = activeProgram {
                                AppleLiveInlinePlayer(request: program.request, coordinator: coordinator,
                                                      playbackRevision: playbackRevision, logoURL: program.artworkURL,
                                                      sharedChannel: nil)
                                    .id(ObjectIdentifier(coordinator))
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Now Playing").font(.caption).foregroundStyle(.secondary)
                                        Text(program.title).font(.headline)
                                            .accessibilityIdentifier("librarytv.nowPlaying")
                                        Text(queue.selectedChannel?.name ?? "Library TV")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Button { playNext() } label: {
                                        Label("Next Video", systemImage: "forward.end.fill")
                                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.primary)
                                    .accessibilityIdentifier("librarytv.next")
                                }
                                .padding(.horizontal)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Channels").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                                ForEach(queue.channels) { channel in
                                    Button {
                                        if let program = queue.select(channelID: channel.id) { tune(program) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "tv").frame(width: 28)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(channel.name).font(.headline)
                                                Text(channel.programs.count == 1 ? "1 video" : "\(channel.programs.count) videos").font(.caption)
                                            }
                                            Spacer()
                                            Image(systemName: queue.selectedChannelID == channel.id ? "speaker.wave.2.fill" : "play.fill")
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(queue.selectedChannelID == channel.id ? .primary : .secondary)
                                    .accessibilityValue(queue.selectedChannelID == channel.id ? "Selected" : "")
                                    .accessibilityIdentifier("librarytv.channel.\(channel.id)")
                        }
                    }
                            .padding(.horizontal)

                            if activeProgram != nil, !queue.upNext().isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Up Next").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                                    ForEach(queue.upNext()) { program in
                                        Text(program.title).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 6)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            ForEach(notices, id: \.self) { notice in
                                Label(notice, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await reload() }
                }
            }
            .navigationTitle("Library TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .tint(.primary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .tint(.primary)
                        .disabled(isLoading)
                }
            }
            .task(id: reloadIdentity) { await reload() }
            .task(id: settings.playbackEngine) {
                coordinator.stop()
                let (engine, fallback) = ApplePlaybackEngineFactory.make(preferred: settings.playbackEngine)
                settings.engineFellBackToNative = fallback
                engine.applyCaptionPreferences(
            preference: settings.captionsPreference,
            languages: settings.subtitleLanguages,
            languagesAreExplicit: settings.hasChosenSubtitleLanguages)
                coordinator = ApplePlaybackCoordinator(engine: engine)
                playbackRevision &+= 1
            }
            .onChange(of: settings.captionsPreference) { _, preference in
                coordinator.engine.applyCaptionPreference(preference)
            }
            .onChange(of: coordinator.phase) { _, phase in
                if case .ended = phase, let program = activeProgram,
                   let next = queue.playbackEnded(programID: program.id) { tune(next) }
            }
            .onDisappear { coordinator.stop(); access = nil }
        }
    }

    private var reloadIdentity: String {
        sourceStore.sources.filter { $0.kind == .library }.map {
            "\($0.id):\($0.configurationRevision):\($0.isEnabled)"
        }.joined(separator: "|")
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        defer { if reloadGeneration == generation { isLoading = false } }
        do {
            let result = try await builder.load(sources: sourceStore.sources)
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            queue.replaceChannels(result.channels)
            notices = Array(Set(result.notices)).sorted()
            if let current = queue.currentProgram {
                if current != activeProgram { tune(current) }
            } else {
                coordinator.stop()
                activeProgram = nil
                access = nil
            }
        } catch is CancellationError {
        } catch {
            if generation == reloadGeneration { notices = ["Library TV could not load because the source scan failed."] }
        }
    }

    private func tune(_ program: AppleLibraryTVProgram) {
        coordinator.stop()
        access = program.securityScopedURL.map { AppleSecurityScopedAccess(url: $0) }
        activeProgram = program
        playbackRevision &+= 1
    }

    private func playNext() { if let next = queue.advance() { tune(next) } }
}
#endif
