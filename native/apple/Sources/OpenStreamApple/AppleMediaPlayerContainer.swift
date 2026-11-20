import SwiftUI

@MainActor
struct AppleMediaPlayerContainer: View {
    let presentation: AppleMediaPlayerPresentation?
    let startup: ApplePlaybackStartup?
    var resolve: (@MainActor () async -> Void)?
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(AppleMacPlayerStage.self) private var macStage: AppleMacPlayerStage?
    #elseif os(visionOS)
    @Environment(AppleVisionPlayerStage.self) private var visionStage: AppleVisionPlayerStage?
    #endif

    private var loading: ApplePlaybackStartup? { startup ?? presentation?.startup }
    private var blocksPlayer: Bool { loading?.isLoading == true || loading?.phase == .timedOut }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let presentation {
                AppleMediaPlayerView(presentation: presentation)
                    .id(presentation.id)
                    .accessibilityHidden(blocksPlayer)
            }
            if loading?.isLoading == true {
                // An opaque stage also covers AVKit's private loading chrome.
                Color.black
                    .overlay {
                        VStack(spacing: AppleDesignTokens.spacingMedium) {
                            ApplePlaybackLoadingIndicator()
                            if loading?.showsConnectionStatus == true {
                                Text(connectionStatus).font(.headline)
                                Button("Retry", action: retry)
                                    .accessibilityIdentifier("player.startup.retry")
                                Button("Cancel", role: .cancel, action: close)
                            }
                        }
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("player.connecting")
                        .accessibilityValue(connectionStatus)
                    }
                    .ignoresSafeArea()
            }
            if loading?.phase == .timedOut {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Playback Timed Out").font(.headline)
                    Button("Retry", action: retry)
                        .accessibilityIdentifier("player.startup.retry")
                    Button("Close", role: .cancel, action: close)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player.startup.timeout")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS) || os(visionOS)
        .overlay(alignment: .topLeading) {
            if blocksPlayer { ApplePlayerCloseButton(action: close) }
        }
        #endif
        .onAppear { loading?.presentationWillAppear() }
        .task(id: loading?.resolutionID) {
            guard loading?.resolutionID != nil else { return }
            await resolve?()
        }
        .task(id: loading?.requestID) {
            guard let loading, loading.isLoading else { return }
            let requestID = loading.requestID
            do { try await Task.sleep(for: ApplePlaybackStartup.connectionFeedbackDelay) } catch { return }
            _ = loading.showConnectionStatus(for: requestID)
        }
        .task(id: loading?.phase) {
            guard let loading, loading.isLoading else { return }
            // The error cover can still yield to this request's first frame.
            _ = await loading.waitForTimeout(for: loading.requestID)
        }
        #if os(tvOS)
        .onExitCommand {
            if blocksPlayer || presentation == nil { close() }
        }
        #endif
    }

    private var connectionStatus: String {
        if let presentation, case .waiting(let message) = presentation.coordinator.phase, let message { return message }
        return loading?.phase == .resolving ? "Connecting…" : "Waiting for the media server…"
    }

    private func close() {
        loading?.cancel()
        presentation?.coordinator.stop()
        #if os(macOS)
        if let macStage { macStage.dismiss() } else { dismiss() }
        #elseif os(visionOS)
        if let visionStage { visionStage.dismiss() } else { dismiss() }
        #else
        dismiss()
        #endif
    }

    private func retry() {
        guard let loading else { return }
        if resolve != nil {
            loading.begin(UUID())
        } else if let presentation {
            loading.cancel()
            loading.handOff()
            Task {
                await presentation.coordinator.begin(presentation.request,
                    fallbackCandidates: presentation.fallbackCandidates)
            }
        }
    }
}
