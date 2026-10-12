import CoreGraphics
import SwiftUI
#if os(visionOS)
import UIKit
#endif

/// The Vision Pro window's shape while it plays, and after.
///
/// The player takes over the app's one window (owner, 2026-10-07: "the
/// player should live in the app ... and the player should be resizable").
/// While it plays, the window keeps its width, takes the film's shape and
/// resizes uniformly from the window bar; when it closes, the window goes
/// back to the size it had. Pure arithmetic, so the SwiftPM gate can test it.
enum AppleVisionPlayerWindowPolicy {
    /// The browse window's opening size (`OpenStreamApps`).
    static let defaultWindowSize = CGSize(width: 1100, height: 760)
    /// The browse window's minimum (`OpenStreamRootView`).
    static let browseMinimum = CGSize(width: 760, height: 540)
    /// The narrowest a playing window may get.
    static let playerMinimumWidth: CGFloat = 640
    static let defaultAspect: CGFloat = 16.0 / 9.0
    /// Square at the narrow end (a vertical clip letterboxes rather than
    /// making the window taller than the wearer can see), Ultra Panavision
    /// at the wide end.
    static let aspectRange: ClosedRange<CGFloat> = 1.0 ... 2.76

    /// The content minimum while the player is up: low enough for the
    /// widest film's floor, so SwiftUI's own minimum never wins over the
    /// aspect-locked one.
    static var playerContentMinimum: CGSize { floor(forAspect: aspectRange.upperBound) }

    /// The picture's aspect, from its pixel size when the engine knows it.
    static func aspect(of videoSize: CGSize?) -> CGFloat {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0,
              videoSize.width.isFinite, videoSize.height.isFinite else { return defaultAspect }
        return clamped(videoSize.width / videoSize.height)
    }

    /// The smallest window for `aspect`, at the same shape.
    static func floor(forAspect aspect: CGFloat?) -> CGSize {
        let aspect = clamped(aspect ?? defaultAspect)
        return CGSize(width: playerMinimumWidth, height: (playerMinimumWidth / aspect).rounded())
    }

    /// The playing window: today's width (never under the floor), and the
    /// height the film's shape gives it.
    static func playerSize(current: CGSize?, aspect: CGFloat?) -> CGSize {
        let aspect = clamped(aspect ?? defaultAspect)
        var width = defaultWindowSize.width
        if let current, current.width.isFinite, current.width > 0 { width = current.width }
        width = max(width, playerMinimumWidth)
        return CGSize(width: width, height: (width / aspect).rounded())
    }

    /// The window after the player closes: the size it had before, or the
    /// opening size when that was never known.
    static func restoredSize(saved: CGSize?) -> CGSize {
        guard let saved, saved.width.isFinite, saved.height.isFinite,
              saved.width > 0, saved.height > 0 else { return defaultWindowSize }
        return saved
    }

    /// Only leaving the foreground stops the player. `.inactive` is a
    /// window the wearer is not looking at, which keeps playing, as a TV
    /// left on in the room does.
    static func stopsPlayback(on phase: ScenePhase) -> Bool {
        phase == .background
    }

    private static func clamped(_ aspect: CGFloat) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return defaultAspect }
        return min(max(aspect, aspectRange.lowerBound), aspectRange.upperBound)
    }
}

#if os(visionOS)
/// The one player the Vision Pro window shows, drawn over the whole window
/// by the root view (`appleVisionPlayerStage(_:)`). The Mac's
/// `AppleMacPlayerStage`, with the window's shape in place of the title bar.
///
/// A page hands its presentation over and gets a callback when the player
/// closes, which is when it clears its own binding — so the page underneath
/// never leaves the window and comes back exactly as it was.
@MainActor
@Observable
final class AppleVisionPlayerStage {
    private(set) var presentation: AppleStremioPlayerPresentation?
    @ObservationIgnored private var onDismiss: (() -> Void)?
    @ObservationIgnored weak var scene: UIWindowScene?
    /// The window's size before the player took it over.
    @ObservationIgnored private var savedSize: CGSize?
    @ObservationIgnored private var fittedAspect: CGFloat?

    init() {}

    var isPresenting: Bool { presentation != nil }

    /// Shows `presentation`, replacing any player already up (whose page is
    /// told it closed).
    func present(_ presentation: AppleStremioPlayerPresentation, onDismiss: @escaping () -> Void) {
        guard self.presentation?.id != presentation.id else { return }
        let replaced = self.onDismiss
        let wasPresenting = isPresenting
        self.presentation = presentation
        self.onDismiss = onDismiss
        if !wasPresenting {
            savedSize = currentSize
            fittedAspect = nil
            fitWindow(aspect: AppleVisionPlayerWindowPolicy.defaultAspect)
        }
        replaced?()
    }

    /// The engine knows the picture's size: the window takes its shape, so a
    /// 2.39:1 film fills it edge to edge.
    func fitVideo(_ videoSize: CGSize?, for id: UUID) {
        guard presentation?.id == id, videoSize != nil else { return }
        let aspect = AppleVisionPlayerWindowPolicy.aspect(of: videoSize)
        guard fittedAspect.map({ abs($0 - aspect) > 0.01 }) ?? true else { return }
        fitWindow(aspect: aspect)
    }

    /// Closes the player. With an `id`, only if that player is still the one
    /// up, so a page clearing a presentation that was already replaced
    /// cannot close its successor.
    func dismiss(id: UUID? = nil) {
        guard let current = presentation, id == nil || id == current.id else { return }
        presentation = nil
        let callback = onDismiss
        onDismiss = nil
        restoreWindow()
        callback?()
    }

    private var currentSize: CGSize? {
        // `effectiveGeometry.coordinateSpace` is visionOS 26; the window's
        // bounds are the same size on every version.
        scene?.windows.first?.bounds.size
    }

    /// Asynchronous and may be refused (a drag in progress, no room in the
    /// space); nothing waits on it.
    private func fitWindow(aspect: CGFloat) {
        fittedAspect = aspect
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: currentSize, aspect: aspect)
        appleTrace("vision stage present \(Int(size.width))x\(Int(size.height))")
        scene?.requestGeometryUpdate(.Vision(
            size: size,
            minimumSize: AppleVisionPlayerWindowPolicy.floor(forAspect: aspect),
            resizingRestrictions: .uniform), errorHandler: nil)
    }

    private func restoreWindow() {
        let size = AppleVisionPlayerWindowPolicy.restoredSize(saved: savedSize)
        savedSize = nil
        fittedAspect = nil
        appleTrace("vision stage dismiss \(Int(size.width))x\(Int(size.height))")
        scene?.requestGeometryUpdate(.Vision(
            size: size,
            minimumSize: AppleVisionPlayerWindowPolicy.browseMinimum,
            resizingRestrictions: .freeform), errorHandler: nil)
    }
}

extension View {
    /// Gives this window a player stage: the player over everything, edge to
    /// edge, with the page underneath kept as it was.
    func appleVisionPlayerStage(_ stage: AppleVisionPlayerStage) -> some View {
        modifier(AppleVisionPlayerStageHost(stage: stage))
    }
}

private struct AppleVisionPlayerStageHost: ViewModifier {
    let stage: AppleVisionPlayerStage

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(stage.isPresenting)
            .overlay {
                if let presentation = stage.presentation {
                    // Black is the bottom layer: the window's glass would
                    // show through anything clear.
                    AppleStremioPlayerView(presentation: presentation)
                        .id(presentation.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.ignoresSafeArea())
                        .preferredColorScheme(.dark)
                        .tint(.white)
                }
            }
            .background {
                AppleVisionWindowReader { stage.scene = $0 }
            }
            .environment(stage)
    }
}

/// Hands back the window scene a view is in, once it is in one.
private struct AppleVisionWindowReader: UIViewRepresentable {
    let onScene: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onScene = onScene
    }

    final class ReaderView: UIView {
        var onScene: (UIWindowScene?) -> Void = { _ in }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onScene(window?.windowScene)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

/// The page's end: hands the presentation to the window's stage and clears
/// the page's binding when the player closes.
struct AppleVisionPlayerStagePresenter: ViewModifier {
    @Binding var presentation: AppleStremioPlayerPresentation?
    @Environment(AppleVisionPlayerStage.self) private var stage: AppleVisionPlayerStage?
    /// A window with no stage (a debug fixture window) gets its own, over
    /// the presenting view.
    @State private var fallbackStage = AppleVisionPlayerStage()

    func body(content: Content) -> some View {
        Group {
            if stage == nil {
                content.appleVisionPlayerStage(fallbackStage)
            } else {
                content
            }
        }
        .onChange(of: presentation?.id, initial: true) { previous, _ in
            let target = stage ?? fallbackStage
            if let presentation {
                target.present(presentation) { [binding = $presentation, id = presentation.id] in
                    if binding.wrappedValue?.id == id { binding.wrappedValue = nil }
                }
            } else if let previous {
                // Only the player this page opened; another page's is not ours.
                target.dismiss(id: previous)
            }
        }
    }
}
#endif
