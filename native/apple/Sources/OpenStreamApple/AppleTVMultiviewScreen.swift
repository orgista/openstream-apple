#if os(tvOS)
import SwiftUI

@MainActor
struct AppleTVMultiviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: AppleTVMultiviewSession
    @FocusState private var focus: String?
    @State private var pickerPresented = false
    @State private var replacingID: String?
    @State private var fullScreen = false
    @State private var footer = AppleTVLiveFooterState()
    @State private var controlsVisible = true
    @State private var controlFocusRequested = false
    @State private var focusRestoreRevision = 0
    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    let onExit: (AppleIPTVChannel) -> Void

    init(initial: [AppleIPTVChannel], channels: [AppleIPTVChannel], guide: AppleIPTVGuide = .init(programmes: []),
         onExit: @escaping (AppleIPTVChannel) -> Void) {
        _session = State(initialValue: AppleTVMultiviewSession(channels: initial))
        self.channels = channels
        self.guide = guide
        self.onExit = onExit
    }

    var body: some View {
        VStack(spacing: 20) {
            GeometryReader { geometry in
                let tiles = session.displayTiles
                let frames = AppleMultiviewPolicy.frames(count: tiles.count, layout: session.policy.layout, size: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(tiles, frames)), id: \.0.id) { tile, frame in
                        AppleTVMultiviewTileView(tile: tile, isAudio: session.policy.audioID == tile.id,
                                                 onSelect: { select(tile.id) }, onBack: exit,
                                                 onChange: { change(tile.id) },
                                                 onPromote: { session.promote(tile.id) },
                                                 onRemove: { remove(tile.id) },
                                                 isFocused: focus == tile.id)
                            .focused($focus, equals: tile.id)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .focusSection()
                .onChange(of: geometry.size, initial: true) { _, size in
                    if size.width > 0 && size.height > 0 && focus == nil { restoreFocus() }
                }
            }
            HStack(spacing: 40) {
                if session.policy.channels.count < 4 {
                    Button("Add Channel", systemImage: "plus", action: add)
                        .focused($focus, equals: "multiview.add")
                        .accessibilityIdentifier("multiview.add")
                }
                if session.policy.channels.count >= 3 {
                    Button(session.policy.layout == .grid ? "1 Big + Smalls" : "Grid", action: session.toggleLayout)
                        .focused($focus, equals: "multiview.layout")
                        .accessibilityIdentifier("multiview.layout")
                }
                Button("Captions", systemImage: "captions.bubble", action: session.toggleCaptions)
                    .accessibilityValue(session.captionsEnabled ? "On" : "Off")
                    .focused($focus, equals: "multiview.captions")
                    .accessibilityIdentifier("multiview.captions")
            }
            .buttonStyle(AppleTVChipStyle(isSelected: false, height: 44, fontSize: 22))
            .opacity(controlsVisible ? 1 : 0)
            .frame(height: 44)
            .focusSection()
        }
        .modifier(ApplePINPresenter())
        .safeAreaInset(edge: .bottom) { AppleImportProgressView() }
        .padding(48)
        .background(.black)
        .foregroundStyle(AppleDesignTokens.textPrimary)
        .defaultFocus($focus, session.policy.audioID ?? "multiview.add", priority: .userInitiated)
        .onChange(of: focus, initial: true) { _, id in
            controlsVisible = true
            if let id { session.focus(id) }
        }
        .task(id: focus) {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if let focus, session.policy.channels.contains(focus), !pickerPresented { controlsVisible = false }
        }
        .interactiveDismissDisabled()
        .task(id: focusRestoreRevision) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !fullScreen && !pickerPresented else { return }
            focus = session.policy.audioID
        }
        .onExitCommand(perform: exit)
        .onKeyPress(.escape) { exit(); return .handled }
        .onMoveCommand(perform: revealControls)
        .task(id: controlsVisible) {
            guard controlsVisible, controlFocusRequested else { return }
            await Task.yield()
            controlFocusRequested = false
            focus = session.policy.channels.count < 4 ? "multiview.add" : "multiview.layout"
        }
        .task(id: "\(scenePhase == .active)|\(fullScreen)") {
            guard scenePhase == .active else {
                session.suspend()
                return
            }
            await session.resume()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                session.traceMetrics()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                guard !Task.isCancelled else { return }
                if let channel = session.thermalChanged() { finish(channel) }
            }
        }
        .onDisappear { if !fullScreen { session.suspend() } }
        .sheet(isPresented: $pickerPresented, onDismiss: restoreFocus) {
            AppleTVMultiviewChannelPicker(channels: channels, guide: guide,
                selectedIDs: Set(session.policy.channels), onSelect: picked)
        }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: returned) {
            if let tile = session.tiles.first(where: { $0.id == session.policy.fullScreenID }) {
                AppleTVLivePlayerScreen(channel: tile.channel, coordinator: tile.coordinator,
                    footerChannels: channels, footer: $footer, guide: guide,
                    onBack: { fullScreen = false }, retainsMultiviewStream: true, onSwitch: switchFullScreen)
                    .id(tile.id)
            }
        }
        .alert("Multiview", isPresented: noticePresented) {
            Button("OK") { session.notice = nil }
        } message: { Text(session.notice ?? "") }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })
    }
    private func revealControls(_ direction: MoveCommandDirection) {
        guard direction == .down, !controlsVisible, let focus,
              let index = session.policy.displayOrder.firstIndex(of: focus) else { return }
        let count = session.policy.channels.count
        let isBottom = count <= 2 || index == count - 1 || (count == 4 && session.policy.layout == .grid && index == 2)
        guard isBottom else { return }
        controlFocusRequested = true
        controlsVisible = true
    }
    private func add() { replacingID = nil; pickerPresented = true }
    private func change(_ id: String) { replacingID = id; pickerPresented = true }
    private func picked(_ channel: AppleIPTVChannel) {
        if let replacingID { session.replace(replacingID, with: channel) } else { session.add(channel) }
        pickerPresented = false
    }
    private func restoreFocus() { focusRestoreRevision &+= 1; controlsVisible = true }
    private func select(_ id: String) { session.select(id); footer.reset(); fullScreen = true }
    private func returned() { session.returnToGrid(); restoreFocus() }
    private func switchFullScreen(_ channel: AppleIPTVChannel) {
        guard let id = session.policy.fullScreenID else { return }
        if !session.policy.channels.contains(channel.id) { session.replace(id, with: channel) }
        session.select(channel.id)
        footer.reset()
    }
    private func remove(_ id: String) {
        if let channel = session.remove(id) { finish(channel) }
        else { restoreFocus() }
    }
    private func exit() { if let channel = session.audioChannel { finish(channel) } }
    private func finish(_ channel: AppleIPTVChannel) {
        appleTrace("multiview exit audio=\(channel.id)")
        session.suspend()
        onExit(channel)
    }
}
#endif
