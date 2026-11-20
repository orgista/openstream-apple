import SwiftUI

#if !os(tvOS)
/// Holds the iPhone portrait hero's page and its cycle: the page changes when
/// its dot has filled, a horizontal swipe moves a page either way, a dot jumps
/// straight to its page, and the timer holds while a finger is on the hero or
/// its trailer is playing (`AppleHeroRotation.cycleIsPaused`); it moves on a
/// second after the trailer ends.
/// Artwork and controls travel together under the drag; Reduce Motion changes pages immediately.
struct AppleHomePhoneHeroCarousel<Page: View>: View {
    /// One id per page, in order.
    let pageIDs: [String]
    /// The bottom of the art to the centre of the page dots. The iPad's
    /// full-bleed hero (N20) sets its own.
    var dotsCentreInset: CGFloat = AppleHomePhoneHeroLayout.dotsCentreInset
    @ViewBuilder let page: (Int) -> Page

    @Environment(\.appleHeroIsCovered) private var isCovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cycle = AppleHeroRotation.Cycle(count: 0)
    @State private var isTouching = false
    @State private var trailer = AppleHomeHeroTrailerStateKey.Value()
    /// Anyone can see the hero (`appleHeroVisibility`); it holds while not.
    @State private var heroIsVisible = false
    @State private var pageWidth: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @GestureState private var dragTranslation = CGSize.zero
    @State private var destinationOffset = 1
    @State private var pageIsChanging = false
    @State private var pageChangeRevision = 0

    var body: some View {
        // The dots sit over the bottom of the art, as the Apple TV app's do,
        // in the room the page leaves under its buttons; they stay put while
        // the pages change.
        ZStack(alignment: .bottom) {
            ZStack {
                if let shown = cycle.pages(available: pageIDs.count)?.shown {
                    ForEach(pageOffsets.map { ((shown + $0) % pageIDs.count + pageIDs.count) % pageIDs.count }, id: \.self) { index in
                        let offset = offset(for: index, shown: shown)
                        page(index)
                            .id(pageIDs[index])
                            .environment(\.appleHeroIsCovered, isCovered || offset != 0)
                            .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
                                guard offset == 0 else { return }
                                let event = state.cycleEvent(after: trailer)
                                trailer = state
                                if let event { cycle.handle(event, at: .now) }
                            }
                            .allowsHitTesting(offset == 0 && !pageIsChanging)
                            .accessibilityHidden(offset != 0)
                            .offset(x: CGFloat(offset == 0 ? 0 : (offset < 0 ? -1 : 1)) * pageWidth + displayedDragOffset)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .clipped()
            .simultaneousGesture(swipe)

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
                                        isHidden: !heroIsVisible || reduceMotion || pageIsChanging)
    }

    /// Horizontal only: vertical drags belong to the page's scroll view, and
    /// the gesture runs alongside it rather than taking its touches.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragTranslation) { value, translation, transaction in
                guard !pageIsChanging, cycle.count > 1 else { return }
                transaction.disablesAnimations = true
                translation = value.translation
            }
            .onChanged { value in
                guard !pageIsChanging, cycle.count > 1 else { return }
                if !isTouching, abs(value.translation.width) > abs(value.translation.height) { isTouching = true }
            }
            .onEnded { value in
                defer { isTouching = false }
                guard !pageIsChanging else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    dragOffset = reduceMotion ? 0 : ApplePhoneHeroSwipe.displacement(value.translation, pageWidth: pageWidth)
                }
                guard let turn = ApplePhoneHeroSwipe.turn(translation: value.translation,
                    predicted: value.predictedEndTranslation, pageWidth: pageWidth) else {
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                    return
                }
                move(by: turn)
            }
    }

    private var displayedDragOffset: CGFloat {
        guard !reduceMotion, !pageIsChanging, dragTranslation != .zero else { return dragOffset }
        return ApplePhoneHeroSwipe.displacement(dragTranslation, pageWidth: pageWidth)
    }

    private var pageOffsets: [Int] {
        guard cycle.count > 1, pageWidth > 0 else { return [0] }
        if pageIsChanging { return [0, destinationOffset] }
        if cycle.count == 2 { return [0, displayedDragOffset > 0 ? -1 : 1] }
        return [-1, 0, 1]
    }

    private func offset(for index: Int, shown: Int) -> Int {
        if index == shown { return 0 }
        if pageIsChanging { return destinationOffset }
        if cycle.count == 2 { return displayedDragOffset > 0 ? -1 : 1 }
        return index == (shown + cycle.count - 1) % cycle.count ? -1 : 1
    }

    /// Holds the timer where it is, or runs it on from there.
    private func holdOrRun() {
        if isPaused { cycle.pause(at: .now) } else { cycle.resume(at: .now) }
        appleTrace("hero cycle \(isPaused ? "held" : "runs") visible=\(heroIsVisible) trailer=\(trailer.isPlaying)")
    }

    private func select(_ position: Int) {
        guard cycle.count > 0 else { return }
        let target = ((position % cycle.count) + cycle.count) % cycle.count
        guard target != cycle.index else { return }
        move(by: target - cycle.index)
    }

    private func move(by offset: Int) {
        guard !pageIsChanging, cycle.count > 1 else { return }
        if reduceMotion {
            step(by: offset)
            return
        }
        destinationOffset = offset
        pageIsChanging = true
        pageChangeRevision &+= 1
        let revision = pageChangeRevision
        withAnimation(.snappy(duration: 0.25)) {
            dragOffset = offset > 0 ? -pageWidth : pageWidth
        } completion: {
            guard pageChangeRevision == revision else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                step(by: offset)
                dragOffset = 0
                pageIsChanging = false
            }
        }
    }

    private func step(by offset: Int) {
        trailer = .init()
        cycle.step(by: offset, at: .now)
        appleTrace("hero cycle page \(cycle.index + 1)/\(cycle.count)")
    }

    /// A new set of pages keeps the one on screen when it is still there,
    /// with a fresh timer; otherwise it starts from the first.
    private func restart(showing id: String?) {
        pageChangeRevision &+= 1
        pageIsChanging = false
        dragOffset = 0
        let index = id.flatMap { pageIDs.firstIndex(of: $0) } ?? 0
        cycle = AppleHeroRotation.Cycle(count: pageIDs.count, index: index)
        if isPaused { cycle.pause(at: .now) }
        appleTrace("hero cycle restart page \(index + 1)/\(pageIDs.count) paused=\(isPaused)")
    }
}
#endif
