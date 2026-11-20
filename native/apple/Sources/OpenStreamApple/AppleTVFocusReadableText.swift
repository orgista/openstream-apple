#if os(tvOS)
import SwiftUI

/// Button text for a tvOS settings Form. The app tints its controls white,
/// and a Form Button draws its label in the tint on the white focus fill too,
/// so the focused row read as a blank capsule; black while focused. A
/// destructive row (Cancel Download, Leave SharePlay) is system red both
/// ways, red on the white capsule while focused as tvOS's destructive alert
/// buttons draw. The focus platter maps a label's brightness to transparency
/// (black stays black, red came out pale pink, even for a
/// `role: .destructive` Button: N74 capture), so the red text is flattened
/// into one opaque layer first.
struct AppleTVFocusReadableText: View {
    private let title: String
    private let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, isDestructive: Bool = false) {
        self.title = title
        self.isDestructive = isDestructive
    }

    var body: some View {
        if isDestructive {
            Text(title)
                .foregroundStyle(isEnabled ? Color.red : Color.secondary)
                .drawingGroup()
        } else {
            Text(title)
                .foregroundStyle(isFocused ? Color.black : (isEnabled ? Color.white : Color.secondary))
        }
    }
}
#endif
