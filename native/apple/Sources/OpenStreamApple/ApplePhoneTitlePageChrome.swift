#if os(iOS)
import SwiftUI

struct ApplePhoneTitlePageChrome: ViewModifier {
    var isEnabled = true
    let title: String
    let heroIsOffscreen: Bool
    let topInset: CGFloat
    let onBack: () -> Void
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .modifier(ApplePhoneHeroChrome(isEnabled: isEnabled, title: title, identifier: "detail.compact-title",
                                          heroIsOffscreen: heroIsOffscreen, topInset: topInset,
                                          showsBarBackground: isScrolled) {
                HStack {
                    backButton
                    Spacer(minLength: 0)
                }
            })
            .onPreferenceChange(ApplePhoneTitlePageScrolledKey.self) { isScrolled = $0 }
    }

    private var backButton: some View {
        backControl.modifier(ApplePhoneHeroControlStyle())
            .accessibilityIdentifier("detail.back")
    }

    private var backControl: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Back")
        .foregroundStyle(.white)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityIdentifier("detail.back")
    }
}

struct ApplePhoneTitlePageScrolledKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The title and landing pages keep a stable overlay while the hero scrolls away.
private struct ApplePhoneHeroChrome<Controls: View>: ViewModifier {
    var isEnabled = true
    let title: String
    let identifier: String
    let heroIsOffscreen: Bool
    let topInset: CGFloat
    var titleInset: CGFloat = 60
    var showsBarBackground = false
    @ViewBuilder let controls: () -> Controls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .toolbar(isEnabled ? .hidden : .visible, for: .navigationBar)
            .overlay(alignment: .top) {
                if isEnabled {
                    LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: topInset + AppleDesignTokens.minimumActionSize)
                        .offset(y: -topInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                if isEnabled {
                    controls()
                        .overlay {
                            // Keep layout fixed; only the visible title has an identifier.
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, titleInset)
                                .opacity(heroIsOffscreen ? 1 : 0)
                                .accessibilityHidden(!heroIsOffscreen)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(heroIsOffscreen ? identifier : "")
                                .allowsHitTesting(false)
                        }
                        .frame(height: AppleDesignTokens.minimumActionSize)
                        .padding(.horizontal, AppleDesignTokens.phoneHeroControlInset)
                        .background {
                            Rectangle()
                                .fill(.bar)
                                .opacity(heroIsOffscreen || showsBarBackground ? 1 : 0)
                                .ignoresSafeArea(edges: .top)
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: heroIsOffscreen)
                }
            }
    }
}

struct ApplePhoneLandingChrome<Accessory: View>: ViewModifier {
    let title: String
    let identifier: String
    let hasHero: Bool
    let isRefreshing: Bool
    let onSearch: () -> Void
    let onRefresh: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @State private var heroIsOffscreen = false
    @State private var topInset: CGFloat = 0
    @Environment(\.appleUsesPadLandingChrome) private var usesPadLandingChrome

    func body(content: Content) -> some View {
        content
            .padding(.top, usesPadLandingChrome || hasHero ? 0 : AppleDesignTokens.minimumActionSize)
            .onPreferenceChange(ApplePhoneLandingHeroOffscreenKey.self) { heroIsOffscreen = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .modifier(ApplePhoneHeroChrome(isEnabled: !usesPadLandingChrome, title: title, identifier: identifier,
                                          heroIsOffscreen: !hasHero || heroIsOffscreen, topInset: topInset, titleInset: 104) {
                HStack(spacing: 8) {
                    accessory()
                    Spacer(minLength: 0)
                    roundControl("Search", symbol: "magnifyingglass", action: onSearch)
                        .accessibilityIdentifier(identifier + ".search")
                    roundControl("Refresh", symbol: "arrow.clockwise", action: onRefresh)
                        .accessibilityIdentifier(identifier + ".refresh")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing)
                        .disabled(isRefreshing)
                }
            })
    }

    private func roundControl(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(label)
        .modifier(ApplePhoneHeroControlStyle())
    }
}

struct ApplePhoneHeroControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .labelStyle(.iconOnly)
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        } else {
            content.appleTitleBarButtonBacking()
        }
    }
}

private struct ApplePhoneLandingHeroOffscreenKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Attached directly to the vertical ScrollView, outside its horizontal shelves.
struct ApplePhoneLandingScrollReader: ViewModifier {
    let layout: AppleHomePhoneHeroLayout
    @State private var heroExtent: CGFloat?
    @State private var heroIsOffscreen = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ApplePhoneLandingHeroExtentKey.self) { extent in
                // A lazy hero leaving the tree must not reset its scroll threshold.
                if let extent, extent > 0 { heroExtent = extent }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let extent = heroExtent ?? (layout.heroHeight - layout.topInset
                    - AppleHomePhoneHeroLayout.trailingOverlap)
                return geometry.contentOffset.y + geometry.contentInsets.top
                    >= extent - AppleDesignTokens.minimumActionSize
            } action: { _, offscreen in heroIsOffscreen = offscreen }
            .preference(key: ApplePhoneLandingHeroOffscreenKey.self, value: heroIsOffscreen)
    }
}

private struct ApplePhoneLandingHeroExtentKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = max(value ?? 0, next) }
    }
}

struct ApplePhoneLandingHeroReader: ViewModifier {
    /// The hero under the phone landing chrome: the phone's, or the iPad's on a large phone window.
    let isUnderPhoneChrome: Bool

    func body(content: Content) -> some View {
        content.background {
            if isUnderPhoneChrome {
                GeometryReader { proxy in
                    Color.clear.preference(key: ApplePhoneLandingHeroExtentKey.self,
                        value: proxy.size.height > 0
                            ? proxy.size.height + AppleHomePhoneHeroLayout.stackTopPadding : nil)
                }
            }
        }
    }
}

#endif
