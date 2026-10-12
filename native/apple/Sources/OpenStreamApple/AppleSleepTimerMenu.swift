import SwiftUI

struct AppleSleepTimerMenu: View {
    let coordinator: ApplePlaybackCoordinator
    var isLive = false
    var transport: AppleTransportOverlayModel?
    var body: some View {
        Menu("Sleep Timer", systemImage: "moon.zzz") {
            AppleSleepTimerChoices(coordinator: coordinator, isLive: isLive, transport: transport)
        }
        .accessibilityIdentifier("player.sleepTimer")
        .holdSleepTimerControls(transport)
    }

    #if os(tvOS)
    static func uiMenu(coordinator: ApplePlaybackCoordinator) -> UIMenu {
        var actions: [UIMenuElement] = [UIAction(title: "Off") { _ in coordinator.sleepTimer.cancel() }]
        for minutes in AppleSleepTimerPolicy.minuteOptions {
            actions.append(UIAction(title: "\(minutes) min") { _ in coordinator.armSleepTimer(minutes: minutes) })
        }
        #if DEBUG
        actions.append(UIAction(title: "1 min (Debug)") { _ in coordinator.armSleepTimer(minutes: 1) })
        #endif
        return UIMenu(title: "Sleep Timer", image: UIImage(systemName: "moon.zzz"), children: actions)
    }
    #endif
}

struct AppleSleepTimerChoices: View {
    let coordinator: ApplePlaybackCoordinator
    var isLive = false
    var transport: AppleTransportOverlayModel?
    var body: some View {
        Button("Off") { coordinator.sleepTimer.cancel() }
            .holdSleepTimerControls(transport)
        ForEach(AppleSleepTimerPolicy.minuteOptions, id: \.self) { minutes in
            Button("\(minutes) min") { coordinator.armSleepTimer(minutes: minutes) }
                .holdSleepTimerControls(transport)
        }
        if isLive, let end = AppleSleepTimerPolicy.programmeDeadline(end: coordinator.sleepProgrammeEnd) {
            Button("End of programme") { coordinator.armSleepTimer(deadline: end) }
                .holdSleepTimerControls(transport)
        }
        #if DEBUG
        Button("1 min (Debug)") { coordinator.armSleepTimer(minutes: 1) }
            .holdSleepTimerControls(transport)
        #endif
    }
}

private extension View {
    func holdSleepTimerControls(_ transport: AppleTransportOverlayModel?) -> some View {
        onAppear { transport?.menuItemAppeared() }
            .onDisappear { transport?.menuItemDisappeared() }
    }
}

struct AppleSleepTimerPresentation: ViewModifier {
    let coordinator: ApplePlaybackCoordinator
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("Still watching?", isPresented: Binding(
            get: { enabled && coordinator.sleepTimer.stillWatching },
            set: { if enabled { coordinator.sleepTimer.stillWatching = $0 } }
        )) {
            Button("Watch Now") { coordinator.engine.play() }
            Button("Stop", role: .cancel) { coordinator.stop() }
        }
    }
}
