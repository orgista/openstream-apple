import SwiftUI

/// What one Apple TV Discover hero page is handed by its carousel: the cycle
/// (for the page dots), the focus the buttons bind to, and whether the paging
/// stops beside them accept focus.
struct AppleHomeTVHeroContext {
    let cycle: AppleHeroRotation.Cycle
    let focus: FocusState<AppleTVHeroPaging.Target?>.Binding
    let pagingEnabled: Bool
    /// Called by a button that opens a page, so focus coming back from it
    /// stays on that button (`AppleTVHeroPaging.entry`).
    var willOpenPage: (AppleTVHeroPaging.Target) -> Void = { _ in }
    /// Called by a button press that leaves the hero up (My List), so the
    /// cycle holds as it does after a focus move (`AppleTVHeroPaging.inputHold`).
    var noteInput: () -> Void = {}
    /// Moves focus by code; the carousel does not count the move as input.
    var moveFocus: (AppleTVHeroPaging.Target) -> Void = { _ in }
}

#if os(tvOS)
/// Holds the Apple TV Discover hero's page and its cycle, as the iPhone and
/// Mac carousels do (same `AppleHeroRotation.Cycle`), and hands the requested
/// page to `AppleHeroPageGate`, which keeps the old page up until the new
/// page's art is decoded. A page whose title has a trailer on the user's
/// server plays it muted over the art (`AppleHeroServerTrailer`). The active
/// dot fills over the cycle; the cycle holds for 5 s after remote input in the
/// hero, under a cover and while its trailer plays, and moves on after the
/// trailer ends; left past the first button and right past the last turn the
/// page (`AppleTVHeroPaging`).
///
/// The buttons are a focus section as wide as the screen, so Down from any
/// tab and Up from any card reach them, and focus that arrives goes to Play,
/// as the Apple TV app's does (`AppleTVHeroPaging.entry`). Up to the tab bar
/// and down to the rows are the focus engine's own moves.
struct AppleHomeTVHeroCarousel<Page: View>: View {
    let pages: [AppleHeroPageArt]
    let slots: AppleHeroPageSlots
    @ViewBuilder let page: (_ index: Int, _ wordmarkFailed: Bool, _ context: AppleHomeTVHeroContext) -> Page

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appleHeroIsCovered) private var isCovered
    @State private var cycle = AppleHeroRotation.Cycle(count: 0)
    @State private var presentationRequest = 0
    @FocusState private var focus: AppleTVHeroPaging.Target?
    /// The button whose page is open; focus coming back from it stays there.
    @State private var returnTarget: AppleTVHeroPaging.Target?
    /// Anyone can see the hero (`appleHeroVisibility`); it holds while not.
    @State private var heroIsVisible = false
    @State private var trailer = AppleHomeHeroTrailerStateKey.Value()
    /// Counts remote input in the hero; each one restarts the hold.
    @State private var inputCount = 0
    @State private var isHoldingForInput = false
    /// The target of the carousel's own last focus write, so its arrival is
    /// not taken for remote input.
    @State private var focusMovedByCode: AppleTVHeroPaging.Target?

    var body: some View {
        let requested = min(cycle.index, max(pages.count - 1, 0))
        AppleHeroPageGate(pages: pages, requested: requested, slots: slots,
                          presentationRequest: presentationRequest) { shown, wordmarkFailed in
            page(shown, wordmarkFailed, AppleHomeTVHeroContext(
                cycle: cycle.indicator(showing: shown),
                focus: $focus,
                pagingEnabled: AppleTVHeroPaging.stopsAreFocusable(focused: focus, pageCount: cycle.count),
                willOpenPage: { returnTarget = $0 },
                noteInput: noteInput,
                moveFocus: moveFocus
            ))
        } onPresent: { shown in
            guard shown == cycle.index else { return }
            cycle.didPresent(at: .now)
        }
        .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
            let ended = state.lastEnd != nil && state.lastEnd != trailer.lastEnd
            trailer = state
            if ended { cycle.videoEnded(at: .now) }
        }
        .onChange(of: focus) { old, target in
            if AppleTVHeroPaging.isRemoteInput(focusedNow: target, movedByCode: focusMovedByCode) {
                noteInput()
            } else {
                focusMovedByCode = nil
            }
            if old == nil, let target {
                let settled = AppleTVHeroPaging.entry(arriving: target, returningTo: returnTarget)
                appleTrace("hero focus: arrived on \(target), settles on \(settled)")
                returnTarget = nil
                if settled != target {
                    moveFocus(settled)
                    return
                }
            }
            guard let turn = AppleTVHeroPaging.turn(for: target) else { return }
            cycle.step(by: turn.offset, at: .now)
            cycle.waitForPresentation()
            presentationRequest &+= 1
            moveFocus(turn.refocus)
        }
        .appleHeroVisibility { visible in
            heroIsVisible = visible
            holdOrRun()
        }
        .onChange(of: isPaused) { holdOrRun() }
        .task(id: inputCount) {
            guard isHoldingForInput else { return }
            do { try await Task.sleep(for: AppleTVHeroPaging.inputHold) } catch { return }
            isHoldingForInput = false
        }
        .onAppear {
            if cycle.count != pages.count { restart(showing: nil) }
        }
        .onChange(of: pages.map(\.id)) { old, _ in
            restart(showing: old.indices.contains(cycle.index) ? old[cycle.index] : nil)
        }
        .task(id: cycle) {
            // Restarted by every change to the cycle, so this only ever waits
            // for the page that is showing.
            guard let due = cycle.dueDate else { return }
            do { try await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0))) } catch { return }
            if cycle.advanceIfDue(at: .now) {
                cycle.waitForPresentation()
                presentationRequest &+= 1
            }
        }
    }

    private var isPaused: Bool {
        reduceMotion || !heroIsVisible || trailer.isPlaying
            || AppleTVHeroPaging.cycleIsPaused(holdingForInput: isHoldingForInput, isCovered: isCovered)
    }

    private func noteInput() {
        inputCount &+= 1
        isHoldingForInput = true
    }

    private func moveFocus(_ target: AppleTVHeroPaging.Target) {
        focusMovedByCode = target
        focus = target
    }

    /// Holds the timer where it is, or runs it on from there.
    private func holdOrRun() {
        if isPaused { cycle.pause(at: .now) } else { cycle.resume(at: .now) }
    }

    /// A new set of pages keeps the one on screen when it is still there,
    /// with a fresh timer; otherwise it starts from the first.
    private func restart(showing id: String?) {
        let index = id.flatMap { id in pages.firstIndex(where: { $0.id == id }) } ?? 0
        cycle = AppleHeroRotation.Cycle(count: pages.count, index: index)
        cycle.waitForPresentation()
        presentationRequest &+= 1
        if isPaused { cycle.pause(at: .now) }
    }
}

/// The Apple TV Discover hero's buttons, after the Apple TV app on tvOS: the
/// white "▶ Resume S1, E3" / "▶ Play" pill, then round My List (+ / ✓) and
/// Details (ⓘ) buttons when the primary plays. A Details primary omits the
/// duplicate round info button. Details stays a button because the title and wordmark
/// are not focusable: making them so would put a stop between Play and the tab
/// bar. The two paging stops sit either side (`AppleTVHeroPaging`).
struct AppleHomeTVHeroActions: View {
    let button: AppleTitlePagePolicy.HeroButton
    let isInList: Bool
    let focus: FocusState<AppleTVHeroPaging.Target?>.Binding
    let pagingEnabled: Bool
    var willOpenPage: (AppleTVHeroPaging.Target) -> Void = { _ in }
    var noteInput: () -> Void = {}
    var moveFocus: (AppleTVHeroPaging.Target) -> Void = { _ in }
    let onPlay: () -> Void
    let onToggleList: () -> Void
    let onDetails: () -> Void

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        HStack(spacing: M.pillGap) {
            pagingStop(.previousPage)
            Button(action: onPlay) {
                AppleTVHeroPrimaryLabel(button: button)
            }
            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: M.pillSize, fontSize: M.pillFontSize))
            .focused(focus, equals: .play)
            .accessibilityIdentifier("home.featured.play")

            Button {
                noteInput()
                onToggleList()
            } label: {
                Label(AppleSemanticAction.myList(saved: isInList).label, systemImage: AppleSemanticAction.myList(saved: isInList).symbol)
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(AppleTVHeroRoundButtonStyle())
            .focused(focus, equals: .myList)
            .accessibilityValue(isInList ? "Saved" : "Not saved")
            .accessibilityIdentifier("home.featured.my-list")

            // A focused Details button outlives a page without one until
            // `restoreAvailableFocus` has moved focus to My List, so the focus
            // engine never sees the focused button vanish and jump to a row.
            if button.showsDetailsButton || focus.wrappedValue == .details {
                Button {
                    willOpenPage(.details)
                    onDetails()
                } label: {
                    Label(AppleSemanticAction.info.label, systemImage: AppleSemanticAction.info.symbol)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(AppleTVHeroRoundButtonStyle())
                .focused(focus, equals: .details)
                .accessibilityIdentifier("home.featured.details")
            }
            pagingStop(.nextPage)
        }
        // The stops take no room: Play stays on the copy's leading edge.
        .padding(.horizontal, -(M.pillGap + M.pagingStopWidth))
        .frame(width: M.actionsFocusWidth, alignment: .leading)
        .focusSection()
        .onAppear(perform: restoreAvailableFocus)
        .onChange(of: focus.wrappedValue) { restoreAvailableFocus() }
        .onChange(of: button.showsDetailsButton) { restoreAvailableFocus() }
    }

    private func restoreAvailableFocus() {
        guard let target = focus.wrappedValue else { return }
        let available = AppleTVHeroPaging.availableTarget(target, showsDetailsButton: button.showsDetailsButton)
        if available != target { moveFocus(available) }
    }

    /// An invisible stop that turns the page the moment it takes focus.
    private func pagingStop(_ target: AppleTVHeroPaging.Target) -> some View {
        Color.clear
            .frame(width: M.pagingStopWidth, height: M.pillSize.height)
            .focusable(pagingEnabled)
            .focusEffectDisabled()
            .focused(focus, equals: target)
            .accessibilityHidden(true)
    }
}

/// A round hero button (My List, Details): a quiet translucent disc at rest,
/// solid white with a black glyph and a small lift when focused — the same
/// treatment as the Play pill beside it (`AppleTVPillStyle`).
struct AppleTVHeroRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        let configuration: ButtonStyleConfiguration

        private typealias M = AppleTVBillboardMetrics

        var body: some View {
            configuration.label
                .font(.system(size: M.pillGlyphSize, weight: .semibold))
                .frame(width: M.pillSize.height, height: M.pillSize.height)
                .background {
                    if isFocused {
                        Circle().fill(.white)
                    } else if reduceTransparency || contrast == .increased {
                        Circle().fill(.background)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .overlay {
                    if contrast == .increased { Circle().stroke(.primary, lineWidth: 2) }
                }
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.06 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 14, y: 6)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(.circle)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// The hero's page dots, driven by its cycle: the active capsule fills over
/// the page's time and stops where it is while the cycle holds. The fill is a
/// local animation, not a timeline, so the full-bleed art is not redrawn to
/// move a 4 pt bar.
struct AppleTVHeroCycleIndicator: View {
    let cycle: AppleHeroRotation.Cycle
    /// The page on screen, which trails `cycle.index` while the gate waits for
    /// the next page's art.
    let index: Int

    @State private var fill: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = AppleTVBillboardMetrics

    private struct Phase: Equatable {
        let cycle: AppleHeroRotation.Cycle
        let index: Int
    }

    var body: some View {
        HStack(spacing: M.rotationSegmentSpacing) {
            ForEach(0 ..< cycle.count, id: \.self) { position in
                let isCurrent = position == index
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(
                        width: isCurrent ? M.rotationActiveSegmentWidth : M.rotationSegmentWidth,
                        height: M.rotationSegmentHeight
                    )
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            Capsule()
                                .fill(.white)
                                .frame(width: M.rotationActiveSegmentWidth * fill)
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: index)
        .accessibilityElement()
        .accessibilityLabel("Featured \(index + 1) of \(cycle.count)")
        .accessibilityIdentifier("home.featured.pages")
        .onChange(of: Phase(cycle: cycle, index: index), initial: true) { _, _ in sync() }
    }

    private func sync() {
        // A page still waiting for its art shows a full bar: its time is up.
        let progress = index == cycle.index ? CGFloat(cycle.progress(at: .now)) : 1
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { fill = reduceMotion ? 1 : progress }
        guard !reduceMotion, !cycle.isPaused, index == cycle.index, progress < 1 else { return }
        withAnimation(.linear(duration: cycle.interval * (1 - progress))) { fill = 1 }
    }
}
#endif
