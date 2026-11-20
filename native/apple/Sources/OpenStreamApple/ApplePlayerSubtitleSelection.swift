import AVFoundation
import Combine
import Foundation

/// Mirrors the system picker without treating audio changes, app selections,
/// or Aether's temporary deselections as a new captions command.
@MainActor
final class ApplePlayerSubtitleSelection {
    private let engine: any ApplePlaybackEngine
    private weak var item: AVPlayerItem?
    private var group: AVMediaSelectionGroup?
    private var observation: AnyCancellable?
    private var criteriaObservation: AnyCancellable?
    private var loading: Task<Void, Never>?
    private var lastOption: AVMediaSelectionOption?
    private var lastObservedOption: AVMediaSelectionOption?
    private var awaitingNativeSelection = false
    private var lastMirroredTrackID: Int?

    init(engine: any ApplePlaybackEngine) { self.engine = engine }

    /// True once the item's legible group has loaded and its selection is
    /// being watched. Tests wait on it instead of sleeping.
    var isObserving: Bool { observation != nil }

    func bind(to item: AVPlayerItem?) {
        // While Picture in Picture or AirPlay holds the picture the caption
        // handoff puts renditions on the item and selects among them itself
        // (`AppleCaptionHandoff`); none of that is a viewer's command, so the
        // mirror stands down until the item is the app's again.
        var item = item
        if let aether = engine as? AetherPlaybackEngine, aether.captionHandoff.stage != .app { item = nil }
        if self.item === item, let item, let group {
            // Auto-selection can happen after the group was bound. Mirror it
            // too, so AVKit cannot keep Off checked over an app-rendered cue.
            if engine.activeSubtitleTrackID != lastMirroredTrackID {
                selectFromApp(id: engine.activeSubtitleTrackID)
            }
            // The native option can precede the engine's late 608 track list.
            // Retry its mapping without turning an unmapped option into Off.
            if lastOption != nil, engine.activeSubtitleTrackID == nil,
               let option = item.currentMediaSelection.selectedMediaOption(in: group) {
                changed(option, in: group)
            }
            return
        }
        // Live TS may have no legible group at the first bind. Retry discovery
        // on the host's next bind tick until a nonempty group is available.
        guard self.item !== item || (item != nil && group == nil && loading == nil) else { return }
        observation = nil
        criteriaObservation = nil
        loading?.cancel()
        loading = nil
        group = nil
        lastOption = nil
        lastObservedOption = nil
        awaitingNativeSelection = false
        lastMirroredTrackID = nil
        self.item = item
        guard let item else { return }
        if let player = engine.avPlayer {
            criteriaObservation = player.publisher(for: \.appliesMediaSelectionCriteriaAutomatically, options: [.new])
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak player, weak item] automatic in
                    MainActor.assumeIsolated {
                        guard !automatic, let self, self.lastOption != nil,
                              let player, self.engine.avPlayer === player,
                              let item, player.currentItem === item else { return }
                        // Aether pins explicit selections to manual criteria.
                        // AVKit's Off/Auto actions need criteria enabled while
                        // the stock player owns the legible rendition.
                        player.appliesMediaSelectionCriteriaAutomatically = true
                    }
                }
        }
        loading = Task { [weak self, item] in
            let loadedGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, self.item === item,
                  self.engine.avPlayer?.currentItem === item else { return }
            self.loading = nil
            guard let group = loadedGroup, !group.options.isEmpty else { return }
            self.group = group
            self.lastOption = nil
            // Capture the immutable selection snapshot before Aether's
            // notification observer can deselect it. Reading the item after
            // hopping to MainActor would lose the viewer's chosen option.
            let notifications = NotificationCenter.default.publisher(
                for: AVPlayerItem.mediaSelectionDidChangeNotification, object: item)
                .compactMap { [weak item] _ in item?.currentMediaSelection }
            self.observation = item.publisher(for: \.currentMediaSelection, options: [.new])
                .merge(with: notifications)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] selection in
                    // Combine delivers on main; the group stays actor-owned.
                    MainActor.assumeIsolated {
                        guard let self, let item, self.item === item,
                              self.engine.avPlayer?.currentItem === item,
                              let group = self.group else { return }
                        let option = selection.selectedMediaOption(in: group)
                        // KVO and the notification can describe the same
                        // change. Audio-only changes also retain this option;
                        // neither may acknowledge a pending native reselect.
                        guard option != self.lastObservedOption else { return }
                        self.lastObservedOption = option
                        self.changed(option, in: group)
                    }
                }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if selected != nil, Self.holdsCaptionsOff(self.engine) {
                // Captions are off and the viewer has not picked a track:
                // AVKit's automatic pick at load is not a command. Mirroring
                // it turned English on over "Off" on some launches (Apple TV
                // verification 2026-10-01).
                self.lastObservedOption = nil
                item.select(nil, in: group)
            } else if let selected {
                // Include a selection made before observation began. This is
                // the default-on path; it must not start with Off checked.
                self.changed(selected, in: group)
                // An already-selected native option need not send a reselect
                // echo. Without this snapshot its first Off looks like a
                // duplicate nil and never reaches the engine/menu.
                if !self.awaitingNativeSelection { self.lastObservedOption = selected }
            } else if let activeID = self.engine.activeSubtitleTrackID {
                self.selectFromApp(id: activeID)
            }
        }
    }

    func selectFromApp(id: Int?) {
        if engine is AetherPlaybackEngine, let id, let group,
           let track = engine.subtitleTracks.first(where: { $0.id == id }), !Self.isBitmap(track),
           let optionIndex = group.options.indices.first(where: {
               Self.trackID(optionIndex: $0,
                            optionLanguages: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                            tracks: Self.renditionOrder(engine.subtitleTracks.filter {
                                $0.id < AetherPlaybackEngine.externalSubtitleTrackIDBase
                            })) == id
           }) {
            // The two menus share a selection, including the native Off row.
            changed(group.options[optionIndex], in: group)
            return
        }
        awaitingNativeSelection = false
        // The engine will deselect the native rendition for sidecar/overlay
        // rendering. That echo must not cancel the newly chosen sidecar.
        lastOption = nil
        engine.selectSubtitleTrack(id: id)
        lastMirroredTrackID = engine.activeSubtitleTrackID
        if engine is NativePlaybackEngine, let group {
            lastOption = id.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
            awaitingNativeSelection = lastOption != nil
        }
    }

    private func changed(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        if awaitingNativeSelection {
            if option == nil { return }
            awaitingNativeSelection = false
        }
        guard option != lastOption || (option != nil && engine.activeSubtitleTrackID == nil) else { return }
        lastOption = option
        if option != nil { engine.avPlayer?.appliesMediaSelectionCriteriaAutomatically = true }
        if let aether = engine as? AetherPlaybackEngine {
            awaitingNativeSelection = aether.mirrorSubtitleSelection(option, in: group)
        } else if let native = engine as? NativePlaybackEngine {
            native.mirrorSubtitleSelection(option)
        }
        lastMirroredTrackID = engine.activeSubtitleTrackID
    }

    /// True while the viewer's captions preference is Off and nothing has
    /// overridden it for this item.
    static func holdsCaptionsOff(_ engine: any ApplePlaybackEngine) -> Bool {
        if let aether = engine as? AetherPlaybackEngine { return aether.holdsCaptionsOff }
        if let native = engine as? NativePlaybackEngine { return native.holdsCaptionsOff }
        return false
    }

    /// Match language and occurrence, not the AVKit ordinal: video/audio
    /// stream IDs and language-sorted rendition positions are different.
    static func trackID(optionIndex: Int, optionLanguages: [String?], tracks: [ApplePlaybackTrack]) -> Int? {
        guard optionLanguages.indices.contains(optionIndex) else { return nil }
        let language = languageKey(optionLanguages[optionIndex])
        let rank = optionLanguages[..<optionIndex].filter {
            languageKey($0) == language
        }.count
        let matches = tracks.filter {
            languageKey($0.language) == language
        }
        guard matches.indices.contains(rank) else { return nil }
        return matches[rank].id
    }

    private static func languageKey(_ language: String?) -> String {
        let key = AppleSubtitleTrackFilter.normalized(language ?? "")
        return key == "und" ? "" : key
    }

    /// Aether appends CC and bitmap renditions after its text tracks. Keep
    /// that ordering when matching same-language options back to stream IDs.
    static func renditionOrder(_ tracks: [ApplePlaybackTrack]) -> [ApplePlaybackTrack] {
        func category(_ track: ApplePlaybackTrack) -> Int {
            if isBitmap(track) { return 2 }
            return ["eia_608", "eia_708", "cea708", "cea_708", "cc"].contains(track.codec?.lowercased() ?? "") ? 1 : 0
        }
        return tracks.enumerated().sorted {
            let lhs = category($0.element), rhs = category($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    nonisolated static func isBitmap(_ track: ApplePlaybackTrack) -> Bool {
        let codec = track.codec?.lowercased() ?? ""
        return ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains { codec.contains($0) }
    }

    isolated deinit {
        observation?.cancel()
        criteriaObservation?.cancel()
        loading?.cancel()
    }
}
