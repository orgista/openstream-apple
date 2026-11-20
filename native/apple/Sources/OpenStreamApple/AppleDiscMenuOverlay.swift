import SwiftUI
import AetherEngine

/// The engine paints the authored highlight. This layer routes input through
/// the actual fitted video rectangle, including after rotation.
struct AppleDiscMenuOverlay: View {
    let engine: AetherPlaybackEngine
    #if os(tvOS)
    @FocusState private var hasRemoteFocus: Bool
    #elseif os(macOS)
    @FocusState private var hasKeyboardFocus: Bool
    #endif

    var body: some View {
        GeometryReader { geometry in
            let picture = AppleVideoFitting.fittedRect(container: geometry.size, videoSize: engine.videoSize)
            ZStack(alignment: .topLeading) {
                #if os(tvOS)
                Button(action: engine.aetherEngine.dvdActivate) {
                    Color.clear.contentShape(.rect)
                }
                .buttonStyle(DiscSurfaceButtonStyle())
                .focused($hasRemoteFocus)
                .defaultFocus($hasRemoteFocus, true)
                .onMoveCommand(perform: navigate)
                .accessibilityLabel("Disc menu")
                .accessibilityValue("Button \(engine.discMenu.state?.highlightedButton ?? 0) of \(engine.discMenu.state?.buttons.count ?? 0)")
                .accessibilityIdentifier("player.disc.menu.select")
                #else
                Color.clear.contentShape(.rect)
                    .onTapGesture { point in activate(point, container: geometry.size) }
                ForEach(engine.discMenu.state?.buttons ?? []) { button in
                    Button { activateButton(button) } label: {
                        Color.clear.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(width: button.frame.width * picture.width, height: button.frame.height * picture.height)
                    .position(x: picture.minX + button.frame.midX * picture.width,
                              y: picture.minY + button.frame.midY * picture.height)
                    .accessibilityLabel("Disc menu button \(button.id)")
                    .accessibilityValue(engine.discMenu.state?.highlightedButton == button.id ? "Selected" : "")
                    .accessibilityIdentifier("player.disc.menu.button.\(button.id)")
                }
                #endif
            }
            #if os(macOS)
            .focusable()
            .focused($hasKeyboardFocus)
            .onAppear { hasKeyboardFocus = true }
            .onKeyPress(.upArrow) { move(.up) }
            .onKeyPress(.downArrow) { move(.down) }
            .onKeyPress(.leftArrow) { move(.left) }
            .onKeyPress(.rightArrow) { move(.right) }
            .onKeyPress(.return) { engine.aetherEngine.dvdActivate(); return .handled }
            .onContinuousHover { phase in
                if case let .active(point) = phase,
                   let normalized = AppleDiscMenuInput.normalizedPoint(point, container: geometry.size, videoSize: engine.videoSize) {
                    engine.aetherEngine.dvdHover(atNormalizedPoint: normalized)
                }
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.disc.menu.active")
    }

    private func activateButton(_ button: DVDMenuButton) {
        engine.aetherEngine.dvdActivate(atNormalizedPoint: CGPoint(x: button.frame.midX, y: button.frame.midY))
    }

    private func activate(_ point: CGPoint, container: CGSize) {
        guard let normalized = AppleDiscMenuInput.normalizedPoint(point, container: container, videoSize: engine.videoSize) else { return }
        engine.aetherEngine.dvdActivate(atNormalizedPoint: normalized)
    }

    #if os(tvOS)
    private func navigate(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: engine.aetherEngine.dvdNavigate(AppleDiscMenuInput.direction(.up))
        case .down: engine.aetherEngine.dvdNavigate(AppleDiscMenuInput.direction(.down))
        case .left: engine.aetherEngine.dvdNavigate(AppleDiscMenuInput.direction(.left))
        case .right: engine.aetherEngine.dvdNavigate(AppleDiscMenuInput.direction(.right))
        @unknown default: break
        }
    }
    #elseif os(macOS)
    private func move(_ direction: AppleDiscMenuInput.Direction) -> KeyPress.Result {
        engine.aetherEngine.dvdNavigate(AppleDiscMenuInput.direction(direction))
        return .handled
    }
    #endif
}

private struct DiscSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
