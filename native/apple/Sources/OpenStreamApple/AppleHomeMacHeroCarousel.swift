#if os(macOS)
import AppKit
import SwiftUI

/// Holds the Mac hero's page and its cycle, as the iPhone's carousel does
/// (`AppleHomePhoneHeroCarousel`, same `AppleHeroRotation.Cycle`): the page
/// changes when its dot has filled, a dot jumps straight to its page, ← and →
/// move a page while the hero has keyboard focus, and a horizontal two-finger
/// swipe on the trackpad moves a page either way. The timer holds while the
/// pointer is over the hero and while its trailer plays with the sound on.
struct AppleHomeMacHeroCarousel<Page: View, Preload: View>: View {
    /// One id per page, in order.
    let pageIDs: [String]
    let layout: AppleMacHeroLayout
    @ViewBuilder let page: (Int) -> Page
    /// Draws a page's art invisibly, so the next page is already decoded when
    /// it slides in.
    @ViewBuilder let preload: (Int) -> Preload

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cycle = AppleHeroRotation.Cycle(count: 0)
    @State private var isHovering = false
    @State private var trailer = AppleHomeHeroTrailerStateKey.Value()
    /// Anyone can see the hero (`appleHeroVisibility`); it holds while not.
    @State private var heroIsVisible = false
    @State private var incomingEdge: Edge = .trailing

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if let shown = cycle.pages(available: pageIDs.count)?.shown {
                    page(shown)
                        .id(pageIDs[shown])
                        .transition(reduceMotion ? .opacity : .push(from: incomingEdge))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: layout.height)
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
            .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
                trailer = state
            }

            if cycle.count > 1 {
                AppleMacHeroPageIndicator(cycle: cycle, onSelect: select)
                    .padding(.bottom, AppleMacHeroLayout.dotsBottomInset
                        - (AppleMacHeroPageDots.hitSize - AppleMacHeroPageDots.dotSize) / 2)
            }
        }
        .overlay {
            // The Apple TV app's ‹ › at the hero's edges, under the pointer
            // only. Vertically centred on the art below the toolbar.
            if cycle.count > 1, isHovering {
                HStack {
                    AppleMacHeroPageChevron(direction: -1) { move(by: -1) }
                    Spacer(minLength: 0)
                    AppleMacHeroPageChevron(direction: 1) { move(by: 1) }
                }
                .padding(.top, layout.topInset)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .background {
            AppleMacHeroSwipeMonitor(isActive: isHovering && cycle.count > 1) { move(by: $0) }
                .allowsHitTesting(false)
        }
        // A stop in the key-view loop of its own, reached with Tab like the
        // buttons in it, so ← and → have somewhere to land.
        .focusable(interactions: .activate)
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured")
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
        #if DEBUG
        .task {
            // `-OpenStreamMacHeroAdvance N` steps the cycle N pages a few
            // seconds after launch, so a headless shot can show a later page.
            let steps = UserDefaults.standard.integer(forKey: "OpenStreamMacHeroAdvance")
            guard steps > 0 else { return }
            try? await Task.sleep(for: .seconds(4))
            for _ in 0 ..< steps {
                guard !Task.isCancelled else { return }
                move(by: 1)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #endif
    }

    private var isPaused: Bool {
        #if DEBUG
        // `-OpenStreamMacHeroHold YES` holds the page, so a headless shot can
        // show one page's art and then its trailer.
        if UserDefaults.standard.bool(forKey: "OpenStreamMacHeroHold") { return true }
        #endif
        return AppleHeroRotation.cycleIsPaused(isTouching: isHovering, trailerIsPlaying: trailer.isPlaying,
                                        trailerIsMuted: trailer.isMuted, trailerWasRequested: trailer.isRequested,
                                        isHidden: !heroIsVisible)
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
        guard cycle.count > 1 else { return }
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

/// The Mac hero's page dots (`AppleMacHeroPageDots`): the active page is a
/// capsule whose white fill runs with the cycle's timer. Each dot is a button
/// that jumps to its page, reachable with Tab and named for VoiceOver.
private struct AppleMacHeroPageIndicator: View {
    let cycle: AppleHeroRotation.Cycle
    let onSelect: (Int) -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: AppleMacHeroPageDots.spacing - (AppleMacHeroPageDots.hitSize - AppleMacHeroPageDots.dotSize)) {
            ForEach(0 ..< cycle.count, id: \.self) { position in
                let size = AppleMacHeroPageDots.size(position: position, index: cycle.index, count: cycle.count)
                Button {
                    onSelect(position)
                } label: {
                    Capsule()
                        .fill(.white.opacity(AppleMacHeroPageDots.inactiveOpacity))
                        .overlay(alignment: .leading) {
                            if position == cycle.index {
                                TimelineView(.animation(minimumInterval: cycle.fillTickInterval(width: size.width, displayScale: displayScale),
                                                         paused: cycle.isPaused)) { context in
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: size.width * cycle.progress(at: context.date))
                                }
                            }
                        }
                        .clipShape(.capsule)
                        .frame(width: size.width, height: size.height)
                        .padding((AppleMacHeroPageDots.hitSize - AppleMacHeroPageDots.dotSize) / 2)
                        .contentShape(.rect)
                }
                .buttonStyle(AppleMacHeroDotStyle())
                .accessibilityLabel("Page \(position + 1) of \(cycle.count)")
                .accessibilityAddTraits(position == cycle.index ? .isSelected : [])
                .help("Page \(position + 1) of \(cycle.count)")
                .animation(.snappy(duration: 0.3), value: cycle.index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.featured.pages")
    }
}

/// A page chevron at the hero's edge: a bare white glyph with a shadow for
/// legibility over bright art, brighter under the pointer.
private struct AppleMacHeroPageChevron: View {
    /// -1 for the previous page, +1 for the next.
    let direction: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: AppleMacHeroLayout.chevronGlyphSize, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.8))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .frame(width: AppleMacHeroLayout.chevronHitWidth, height: AppleMacHeroLayout.chevronHitHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .accessibilityLabel(direction < 0 ? "Previous" : "Next")
        .help(direction < 0 ? "Previous" : "Next")
        .accessibilityIdentifier(direction < 0 ? "home.featured.previous" : "home.featured.next")
    }
}

/// A dot brightens under the pointer and dims while held.
private struct AppleMacHeroDotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Dot(configuration: configuration)
    }

    private struct Dot: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(isHovered ? 0.15 : 0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }
}

/// Watches the trackpad's scroll events while the pointer is over the hero
/// and turns one horizontal swipe into one page (`AppleMacHeroSwipe`).
/// Vertical scrolling passes through to the page untouched.
private struct AppleMacHeroSwipeMonitor: NSViewRepresentable {
    let isActive: Bool
    let onSwipe: (Int) -> Void

    @MainActor
    final class Coordinator {
        var onSwipe: (Int) -> Void = { _ in }
        private var monitor: Any?
        private var swipe = AppleMacHeroSwipe()

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event) }
                    return event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            // Precise (trackpad / Magic Mouse) scrolling only; momentum after
            // the fingers lift never turns a page.
            guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return }
            if event.phase.contains(.began) { swipe.begin() }
            if let direction = swipe.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
                onSwipe(direction)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }
}
#endif
