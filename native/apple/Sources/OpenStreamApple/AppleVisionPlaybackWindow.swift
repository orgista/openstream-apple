#if os(visionOS)
import Observation
import SwiftUI

/// Keeps the session alive independently of the browsing window.
@MainActor
@Observable
final class AppleVisionPlaybackWindow {
    static let shared = AppleVisionPlaybackWindow()
    static let sceneID = "openstream-player"
    var presentation: AppleStremioPlayerPresentation?
}

@MainActor
public struct AppleVisionPlaybackScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup("Player", id: AppleVisionPlaybackWindow.sceneID) {
            AppleVisionPlayerWindowContent()
        }
        .defaultSize(width: 1100, height: 620)
        .windowResizability(.contentMinSize)
    }
}

private struct AppleVisionPlayerWindowContent: View {
    @State private var window = AppleVisionPlaybackWindow.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let presentation = window.presentation {
                AppleStremioPlayerView(presentation: presentation)
                    .id(presentation.id)
                    .onDisappear {
                        if window.presentation?.id == presentation.id {
                            window.presentation = nil
                        }
                    }
            } else {
                Color.black
                    .task { dismissWindow(id: AppleVisionPlaybackWindow.sceneID) }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

struct AppleVisionPlayerPresentationModifier: ViewModifier {
    @Binding var presentation: AppleStremioPlayerPresentation?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: presentation?.id, initial: true) {
            guard let presentation else { return }
            AppleVisionPlaybackWindow.shared.presentation = presentation
            openWindow(id: AppleVisionPlaybackWindow.sceneID)
            self.presentation = nil
        }
    }
}
#endif
