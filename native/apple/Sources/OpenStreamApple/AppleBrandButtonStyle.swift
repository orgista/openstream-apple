import SwiftUI

/// Primary action button for OpenStream: a white fill with a black label,
/// matching the launch screen, the store assets, and the web portal button.
///
/// It replaces `.borderedProminent`, which — under the app's white brand tint —
/// renders a white label on the white fill (the unreadable "white on white"
/// the owner reported on the Live tab's Open Settings button). The brand is
/// monochrome, so the accent is white and the primary button inverts to keep
/// contrast; nothing in the app reads as the iOS default blue.
/// The brand buttons' background shape.
///
/// Not a `Capsule`. A capsule's corner radius is always half its height, so a
/// label that wraps turns the button into an **ellipse**, and an ellipse is
/// narrower at its top and bottom than the text it is meant to contain: at the
/// largest accessibility text size "Start Web Management" wrapped to three lines
/// and the first and last lines sat *outside* the white fill (measured on the
/// phone, 2026-09-17).
///
/// `RoundedRectangle` clamps its radius to half the smaller dimension, so at
/// every ordinary single-line height (44–56 pt) this draws exactly the same pill
/// a capsule did, and only once the label wraps does it become a rounded
/// rectangle — which is full width at every height, so the text stays inside it.
private let appleBrandButtonCornerRadius: CGFloat = 30

private var appleBrandButtonShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: appleBrandButtonCornerRadius, style: .continuous)
}

public struct AppleBrandPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        /// A Mac form's primary action is a free-standing button
        /// (`AppleFormActionBar`), and a disabled one — Add Catalog with no
        /// URL yet — looked exactly like a live one.
        private var disabledOpacity: Double {
            #if os(macOS)
            isEnabled ? 1 : 0.4
            #else
            1
            #endif
        }

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .frame(minHeight: AppleDesignTokens.minimumActionSize)
                .background(.white, in: appleBrandButtonShape)
                .overlay {
                    RoundedRectangle(cornerRadius: appleBrandButtonCornerRadius + 7, style: .continuous)
                        .stroke(.white.opacity(isFocused ? 0.95 : 0), lineWidth: 4)
                        .padding(-7)
                }
                .shadow(color: .white.opacity(isFocused ? 0.42 : 0), radius: 16)
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.06 : 1))
                .opacity((configuration.isPressed ? 0.7 : 1) * disabledOpacity)
                .contentShape(appleBrandButtonShape)
                .appleHoverAffordance()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

public extension ButtonStyle where Self == AppleBrandPrimaryButtonStyle {
    static var brandPrimary: AppleBrandPrimaryButtonStyle { AppleBrandPrimaryButtonStyle() }
}

/// Secondary actions keep a dark translucent surface and white label so the
/// app's monochrome tint cannot produce white-on-white controls on tvOS.
public struct AppleBrandSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.48))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .frame(minHeight: AppleDesignTokens.minimumActionSize)
                .background(
                    isFocused ? Color(white: 0.28) : Color(white: 0.14),
                    in: appleBrandButtonShape
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: appleBrandButtonCornerRadius + (isFocused ? 7 : 0),
                        style: .continuous
                    )
                    .stroke(.white.opacity(isFocused ? 0.96 : 0.34), lineWidth: isFocused ? 4 : 1)
                    .padding(isFocused ? -7 : 0)
                }
                .shadow(color: .white.opacity(isFocused ? 0.34 : 0), radius: 14)
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.06 : 1))
                .opacity(configuration.isPressed ? 0.72 : 1)
                .contentShape(appleBrandButtonShape)
                .appleHoverAffordance()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

public extension ButtonStyle where Self == AppleBrandSecondaryButtonStyle {
    static var brandSecondary: AppleBrandSecondaryButtonStyle { AppleBrandSecondaryButtonStyle() }
}

/// Keeps the system tvOS focus fill readable for controls that use the
/// platform's row treatment. tvOS applies the light focus surface outside the
/// button label, while the app's global white tint otherwise leaves labels and
/// SF Symbol icons white on white.
public struct AppleTVReadableFocusModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        // Stock tvOS list rows already lift and brighten on focus; no inner
        // button chrome (a bordered white capsule read as a box in a box).
        content
    }
}

public struct AppleTVNavigationLabel: View {
    private let title: String
    /// Nil for a row in a pane whose other rows carry no glyph: the Playback
    /// pane had five value rows without one and two navigation rows with one,
    /// which read as an accident (review 2026-09-14, U6).
    private let systemImage: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The icon slot has to grow with the type: an SF Symbol scales with
    /// Dynamic Type, so a fixed slot is overrun by its own glyph at
    /// accessibility sizes and the symbol lands on top of the title.
    @ScaledMetric(relativeTo: .body) private var iconSlot: CGFloat =
        AppleTVNavigationLabel.compactIconSlotWidth

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        #if os(tvOS)
        // A stock `Label` in a tvOS list sizes its icon column to the font, so
        // wide symbols (folder.badge.plus, dot.radiowaves.left.and.right,
        // network) run straight into the title. A fixed slot keeps every
        // glyph clear of the text and starts all titles on the same column.
        HStack(spacing: AppleTVNavigationLabel.iconSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.primary)
                    .frame(width: AppleTVNavigationLabel.iconSlotWidth)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .accessibilityElement(children: .combine)
        #else
        if let systemImage {
            if AppleTVNavigationLabel.usesFixedIconColumn(for: dynamicTypeSize) {
                // A stock `Label` re-flows at accessibility sizes and lets the
                // wrapped line escape the title column: "Channel Manager" put
                // "Manager" on a second line starting at the row's leading
                // edge, underneath the glyph. The fixed slot is the same thing
                // the tvOS branch above does, and for the same reason.
                HStack(alignment: .firstTextBaseline,
                       spacing: AppleTVNavigationLabel.isMacPlatform
                           ? AppleTVNavigationLabel.macIconSpacing : AppleTVNavigationLabel.iconSpacing) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.primary)
                        .frame(width: AppleTVNavigationLabel.isMacPlatform ? AppleTVNavigationLabel.macIconSlotWidth : iconSlot,
                               alignment: AppleTVNavigationLabel.isMacPlatform ? .center : .leading)
                        .accessibilityHidden(true)
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            } else {
                Label {
                    Text(title)
                } icon: {
                    // Decorative: the title carries the row's meaning. Left
                    // visible, VoiceOver read the symbol's name with it
                    // ("rectangle.stack.badge.plus", "Icloud Upload"; iOS 18.6
                    // regression 2026-10-01).
                    Image(systemName: systemImage)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
                // The row reads as its title alone.
                .accessibilityRepresentation { Text(title) }
                // The same style again, on the outside.
                //
                // On macOS a `Label` inside a `List` row re-tints its icon
                // after the icon closure has been evaluated, so the
                // `.foregroundStyle(.primary)` above lost and every glyph in
                // the Sources list drew in the system accent — measured
                // rgb(92,121,245) against a white-tinted app (macOS sweep,
                // 2026-09-21), which breaks the owner's "nothing blue except
                // the brand mark" rule. Applied out here it wins, and it is a
                // no-op on iOS and visionOS, where the title is `.primary`
                // already and the icon was never re-tinted.
                .foregroundStyle(.primary)
            }
        } else {
            Text(title)
        }
        #endif
    }

    /// Whether to take the icon column over from `Label`.
    ///
    /// On iOS and visionOS only at accessibility sizes: at ordinary sizes the
    /// stock label is correct and matches every other iOS settings screen, so
    /// it is left alone. On the Mac always: a macOS `Label` sizes its icon
    /// column to each glyph, so titles started wherever their symbol ended —
    /// "Metadata" (photo.on.rectangle.angled) sat 4 pt right of "Sources" and
    /// "Radarr & Sonarr" 1 pt left, in the same list (N54, 1440 pt window).
    /// System Settings centres its glyphs in one column; so does this.
    public static func usesFixedIconColumn(for size: DynamicTypeSize, isMac: Bool = isMacPlatform) -> Bool {
        isMac || size.isAccessibilitySize
    }

    public static var isMacPlatform: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The Mac's column: the stock label's glyph-to-title distance (27 pt,
    /// measured on the Settings list) kept, with the glyph centred in it.
    public static let macIconSlotWidth: CGFloat = 20
    public static let macIconSpacing: CGFloat = 7

    /// Widest tvOS body-size symbol in the settings rows is ~42 pt.
    public static let iconSlotWidth: CGFloat = 48
    public static let iconSpacing: CGFloat = 12
    /// The phone's glyphs are drawn at body size, not tvOS's, so the slot that
    /// keeps titles on one column there is far wider than this needs.
    public static let compactIconSlotWidth: CGFloat = 30
}

public extension View {
    func appleTVReadableFocus() -> some View {
        modifier(AppleTVReadableFocusModifier())
    }
}


/// Switches take the brand accent; everything else keeps the app's white tint.
///
/// The app tints itself white so nothing reads as the iOS default blue. That
/// also tinted every `Toggle`, and a white ON track under a white knob is a
/// switch you can only read from the knob's drop shadow — "the toggles in
/// settings are not great" (owner, 2026-09-17). This re-wraps each switch in the
/// stock style with the brand accent — #FF3366, already the favourites and
/// now-line colour, so it is inside "nothing blue but the brand mark" — and is
/// applied once at each root, so buttons and links beside a switch stay white.
public struct AppleBrandToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        // Apple TV has no switch track to colour — its Toggle is a row with an
        // "On"/"Off" label — and the tint landed on the label text instead.
        // Left exactly as the platform draws it.
        Toggle(configuration)
        #else
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green) // the classic iOS switch (owner, 2026-09-17)
        #endif
    }
}

public extension ToggleStyle where Self == AppleBrandToggleStyle {
    static var brandSwitch: AppleBrandToggleStyle { AppleBrandToggleStyle() }
}

#if os(tvOS)
/// Apple TV draws a Toggle as a row that turns white when focused, and the
/// settings forms' white tint drew its title white on that fill: the focused
/// Enabled and catalog rows read as a blank capsule with only "On" left
/// (full test 2026-10-01). The title is black while focused, white otherwise,
/// as `AppleTVFocusReadableText` does for buttons. The inner Toggle takes the
/// platform style, so this style is not applied to itself again.
public struct AppleTVReadableToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            AppleTVFocusReadableLabel { configuration.label }
        }
        .toggleStyle(.automatic)
    }
}

public extension ToggleStyle where Self == AppleTVReadableToggleStyle {
    static var tvReadable: AppleTVReadableToggleStyle { AppleTVReadableToggleStyle() }
}

/// Any label inside a focusable tvOS row: black on the white focus fill,
/// white (or secondary when disabled) otherwise.
struct AppleTVFocusReadableLabel<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(isFocused ? Color.black : (isEnabled ? Color.white : Color.secondary))
    }
}
#endif
