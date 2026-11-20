import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The viewer's subtitle timing for the title playing: a delay and an
/// optional frame-rate fix, set from the subtitle menu. Per play: the
/// coordinator holds it and starts every new title at zero
/// (`ApplePlaybackCoordinator.subtitleTiming`); nothing is saved.
///
/// Applied to the cue clock, not to the cues: the cue layer asks which cues
/// are active at `cueClock(at:)`, so a dense track costs nothing extra per
/// tick. AVKit's own embedded-track rendering (the stock player drawing a
/// native legible track) is out of reach and does not move.
public struct AppleSubtitleTiming: Equatable, Sendable {
    /// A subtitle file timed for one frame rate played against video at the
    /// other drifts further every minute (a PAL 25 fps SRT on a 23.976 fps
    /// film ends about 4 % early). The ratio stretches the cue times back.
    public enum FrameRateFix: String, CaseIterable, Sendable, Identifiable {
        case off
        /// Subtitles made for 25 fps, video at 23.976 fps.
        case from25To23976
        /// Subtitles made for 23.976 fps, video at 25 fps.
        case from23976To25

        public var id: String { rawValue }

        /// Multiplies a cue's file time to give its video time.
        public var scale: Double {
            switch self {
            case .off: 1
            case .from25To23976: 25 / 23.976
            case .from23976To25: 23.976 / 25
            }
        }

        public var title: String {
            switch self {
            case .off: "Off"
            case .from25To23976: "25 → 23.976 fps"
            case .from23976To25: "23.976 → 25 fps"
            }
        }
    }

    /// Seconds; positive shows each cue later, negative earlier.
    public private(set) var delay: Double
    public var frameRateFix: FrameRateFix

    /// The engine keeps about a minute of cues ahead of the playhead and
    /// five behind, so an earlier-than-30 s pull would find nothing to show.
    public static let delayLimit: Double = 30

    public init(delay: Double = 0, frameRateFix: FrameRateFix = .off) {
        self.delay = Self.clamped(delay)
        self.frameRateFix = frameRateFix
    }

    public var isIdentity: Bool { delay == 0 && frameRateFix == .off }

    /// The file time to look cues up at for the frame at `presentationTime`.
    public func cueClock(at presentationTime: Double) -> Double {
        (presentationTime - delay) / frameRateFix.scale
    }

    /// `cue` as it is drawn: both ends stretched and shifted, never before 0.
    public func adjusted(_ cue: AppleSubtitleCue) -> AppleSubtitleCue {
        AppleSubtitleCue(id: cue.id,
                         startTime: max(0, cue.startTime * frameRateFix.scale + delay),
                         endTime: max(0, cue.endTime * frameRateFix.scale + delay),
                         body: cue.body)
    }

    /// Moves the delay by `step` seconds, within ±`delayLimit`.
    public mutating func nudge(by step: Double) {
        delay = Self.clamped(delay + step)
    }

    public mutating func resetDelay() { delay = 0 }

    /// One menu action. Menus hand back a change rather than a whole value
    /// because a menu that stays open keeps its first snapshot.
    public enum Change: Equatable, Sendable {
        case nudge(Double)
        case resetDelay
        case frameRate(FrameRateFix)
    }

    public mutating func apply(_ change: Change) {
        switch change {
        case .nudge(let step): nudge(by: step)
        case .resetDelay: resetDelay()
        case .frameRate(let fix): frameRateFix = fix
        }
    }

    /// "+150 ms", "−1.25 s", "0 ms": what the menu shows beside "Subtitle Delay".
    public var delayLabel: String {
        let ms = Int((delay * 1000).rounded())
        let sign = ms > 0 ? "+" : ms < 0 ? "−" : ""
        let magnitude = abs(ms)
        if magnitude < 1000 { return "\(sign)\(magnitude) ms" }
        let seconds = Double(magnitude) / 1000
        return "\(sign)\(seconds.formatted(.number.precision(.fractionLength(2)))) s"
    }

    /// Whole milliseconds, so ten 0.1 s nudges land on exactly 1 s.
    private static func clamped(_ seconds: Double) -> Double {
        let ms = (seconds * 1000).rounded()
        return min(delayLimit, max(-delayLimit, ms / 1000))
    }
}

/// The subtitle menu's timing rows, shared by the SwiftUI, UIKit and AppKit
/// menus so every platform offers the same steps.
enum AppleSubtitleTimingMenu {
    struct Step: Equatable, Identifiable {
        let title: String
        let seconds: Double
        var id: String { title }
    }

    static let title = "Subtitle Delay"
    static let frameRateTitle = "Frame Rate"
    static let resetTitle = "Reset"

    static let steps: [Step] = [
        Step(title: "+100 ms", seconds: 0.1),
        Step(title: "+50 ms", seconds: 0.05),
        Step(title: "−50 ms", seconds: -0.05),
        Step(title: "−100 ms", seconds: -0.1),
    ]

    /// "Subtitle Delay  +150 ms" where a menu row has one line only.
    static func titleWithValue(_ timing: AppleSubtitleTiming) -> String {
        "\(title)  \(timing.delayLabel)"
    }

    /// Delay is offered only while a subtitle track is on.
    static func isOffered(subtitleSelected: Bool) -> Bool { subtitleSelected }
}

/// "Subtitle Delay" (its steps stay open for repeated nudges) and "Frame
/// Rate", for a SwiftUI subtitle menu.
struct AppleSubtitleTimingMenus: View {
    let timing: AppleSubtitleTiming
    let change: (AppleSubtitleTiming.Change) -> Void
    var onItemAppeared: () -> Void = {}
    var onItemDisappeared: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(AppleSubtitleTimingMenu.steps) { step in
                Button(step.title) { change(.nudge(step.seconds)) }
                    #if !os(macOS)
                    // Repeated nudges without reopening the menu.
                    .menuActionDismissBehavior(.disabled)
                    #endif
                    .accessibilityIdentifier("player.subtitle.delay.\(step.seconds)")
                    .onAppear(perform: onItemAppeared)
                    .onDisappear(perform: onItemDisappeared)
            }
            Button(AppleSubtitleTimingMenu.resetTitle) { change(.resetDelay) }
                .disabled(timing.delay == 0)
                .accessibilityIdentifier("player.subtitle.delay.reset")
        } label: {
            Text(AppleSubtitleTimingMenu.title)
            Text(timing.delayLabel)
        }
        .accessibilityIdentifier("player.subtitle.delay")
        .accessibilityValue(timing.delayLabel)
        .onAppear(perform: onItemAppeared)
        .onDisappear(perform: onItemDisappeared)
        Menu {
            ForEach(AppleSubtitleTiming.FrameRateFix.allCases) { fix in
                Button { change(.frameRate(fix)) } label: {
                    if timing.frameRateFix == fix {
                        Label(fix.title, systemImage: "checkmark")
                    } else {
                        Text(fix.title)
                    }
                }
                .accessibilityIdentifier("player.subtitle.fps.\(fix.rawValue)")
            }
        } label: {
            Text(AppleSubtitleTimingMenu.frameRateTitle)
            Text(timing.frameRateFix.title)
        }
        .accessibilityIdentifier("player.subtitle.fps")
        .onAppear(perform: onItemAppeared)
        .onDisappear(perform: onItemDisappeared)
    }
}

#if canImport(UIKit) && !os(watchOS)
extension AppleSubtitleTimingMenu {
    /// The delay and frame-rate submenus for a UIKit captions menu.
    @MainActor
    static func uiMenus(
        timing: AppleSubtitleTiming,
        apply: @escaping @MainActor (AppleSubtitleTiming.Change) -> Void
    ) -> [UIMenuElement] {
        var stepActions: [UIMenuElement] = steps.map { step in
            let action = UIAction(title: step.title, attributes: .keepsMenuPresented) { _ in apply(.nudge(step.seconds)) }
            action.accessibilityIdentifier = "player.subtitle.delay.\(step.seconds)"
            return action
        }
        let reset = UIAction(title: resetTitle,
                             attributes: timing.delay == 0 ? .disabled : []) { _ in apply(.resetDelay) }
        reset.accessibilityIdentifier = "player.subtitle.delay.reset"
        stepActions.append(reset)
        let delayMenu = UIMenu(title: titleWithValue(timing), image: UIImage(systemName: "timer"),
                               children: stepActions)
        let rateMenu = UIMenu(title: frameRateTitle, options: .singleSelection,
                              children: AppleSubtitleTiming.FrameRateFix.allCases.map { fix in
            let action = UIAction(title: fix.title, state: timing.frameRateFix == fix ? .on : .off) { _ in
                apply(.frameRate(fix))
            }
            action.accessibilityIdentifier = "player.subtitle.fps.\(fix.rawValue)"
            return action
        })
        delayMenu.accessibilityIdentifier = "player.subtitle.delay"
        rateMenu.accessibilityIdentifier = "player.subtitle.fps"
        return [delayMenu, rateMenu]
    }
}
#endif
