import Observation

/// Owned by the full-screen controller, so replacing its SwiftUI root during
/// rotation or playback updates cannot replace an open picker's state.
@MainActor
@Observable
final class AppleLiveChannelPickerState {
    private(set) var isPresented = false

    func show() { isPresented = true }

    func dismiss() { isPresented = false }

    func select(_ channel: AppleIPTVChannel, onSelect: (AppleIPTVChannel) -> Void) {
        // Close before the callback: switching a stream can update the host
        // immediately. This action never dismisses the full-screen controller.
        dismiss()
        onSelect(channel)
    }
}
