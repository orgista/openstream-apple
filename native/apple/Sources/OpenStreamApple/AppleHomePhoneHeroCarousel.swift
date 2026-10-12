import SwiftUI

#if !os(tvOS)
/// Holds the iPhone portrait hero's page and its cycle: the page changes when
/// its dot has filled, a horizontal swipe moves a page either way, a dot jumps
/// straight to its page, and the timer holds while a finger is on the hero or
/// its trailer is playing (`AppleHeroRotation.cycleIsPaused`).
/// With Reduce Motion the pages cross-fade instead of sliding.
struct AppleHomePhoneHeroCarousel<Page: View, Preload: View>: View {
    /// One id per page, in order.
    let pageIDs: [String]
    /// The bottom of the art to the centre of the page dots. The iPad's
    /// full-bleed hero (N20) sets its own.
    var dotsCentreInset: CGFloat = AppleHomePhoneHeroLayout.dotsCentreInset
    @ViewBuilder let page: (Int) -> Page
    /// Draws a page's art invisibly, so the next page is already decoded when
    /// it slides in rather than arriving as a bare surface under its copy.
    @ViewBuilder let preload: (Int) -> Preload

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cycle = AppleHeroRotation.Cycle(count: 0)
    @State private var isTouching = false
    @State private var trailer = AppleHomeHeroTrailerStateKey.Value()
    /// Anyone can see the hero (`appleHeroVisibility`); it holds while not.
    @State private var heroIsVisible = false
    /// The edge the incoming page slides in from.
    @State private var incomingEdge: Edge = .trailing

    var body: some View {
        // The dots sit over the bottom of the art, as the Apple TV app's do,
        // in the room the page leaves under its buttons; they stay put while
        // the pages slide.
        ZStack(alignment: .bottom) {
            ZStack {
                if let shown = cycle.pages(available: pageIDs.count)?.shown {
                    page(shown)
                        .id(pageIDs[shown])
                        .transition(reduceMotion ? .opacity : .push(from: incomingEdge))
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .background {
                if let next = cycle.pages(available: pageIDs.count)?.next {
                    preload(next)
                        .id(pageIDs[next])
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(swipe)
            .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
                trailer = state
            }

            if cycle.count > 1 {
                AppleHomePhoneHeroPageIndicator(cycle: cycle, onSelect: select)
                    .padding(.bottom, dotsCentreInset - AppleHomePhoneHeroPageIndicator.height / 2)
            }
        }
        .onAppear {
            if cycle.count != pageIDs.count { restart(showing: nil) }
        }
        .onChange(of: pageIDs) { old, _ in
            restart(showing: old.indices.contains(cycle.index) ? old[cycle.index] : nil)
        }
        .appleHeroVisibility { visible in
            heroIsVisible = visible
            holdOrRun()
        }
        .onChange(of: isPaused) { holdOrRun() }
        .task(id: cycle) {
            // Restarted by every change to the cycle, so this only ever waits
            // for the page that is showing.
            guard let due = cycle.dueDate else { return }
            do { try await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0))) } catch { return }
            move(by: 1)
        }
    }

    private var isPaused: Bool {
        AppleHeroRotation.cycleIsPaused(isTouching: isTouching, trailerIsPlaying: trailer.isPlaying,
                                        trailerIsMuted: trailer.isMuted, trailerWasRequested: trailer.isRequested,
                                        isHidden: !heroIsVisible)
    }

    /// Horizontal only: vertical drags belong to the page's scroll view, and
    /// the gesture runs alongside it rather than taking its touches.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if !isTouching, abs(value.translation.width) > abs(value.translation.height) { isTouching = true }
            }
            .onEnded { value in
                defer { isTouching = false }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height), abs(dx) > 50 || abs(value.predictedEndTranslation.width) > 160
                else { return }
                move(by: dx < 0 ? 1 : -1)
            }
    }

    /// Holds the timer where it is, or runs it on from there.
    private func holdOrRun() {
        if isPaused { cycle.pause(at: .now) } else { cycle.resume(at: .now) }
    }

    private func select(_ position: Int) {
        guard cycle.count > 0 else { return }
        let target = ((position % cycle.count) + cycle.count) % cycle.count
        guard target != cycle.index else { return }
        move(by: target - cycle.index)
    }

    private func move(by offset: Int) {
        incomingEdge = offset >= 0 ? .trailing : .leading
        withAnimation(reduceMotion ? .easeInOut(duration: 0.35) : .smooth(duration: 0.45)) {
            cycle.step(by: offset, at: .now)
        }
    }

    /// A new set of pages keeps the one on screen when it is still there,
    /// with a fresh timer; otherwise it starts from the first.
    private func restart(showing id: String?) {
        let index = id.flatMap { pageIDs.firstIndex(of: $0) } ?? 0
        cycle = AppleHeroRotation.Cycle(count: pageIDs.count, index: index)
        if isPaused { cycle.pause(at: .now) }
    }
}
#endif
