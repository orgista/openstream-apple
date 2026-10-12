import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Credits and the content statement the App Store build has to carry.
///
/// TMDB's API terms require its logo and the exact notice below wherever the
/// app credits its metadata; TMDB's watch-provider data comes from JustWatch,
/// which asks for its own credit wherever that data is shown. OpenStream ships
/// no content, and the empty states say so.
///
/// None of it is printed on the screens themselves: the owner's call on the
/// first pass (a6765b2) was "just make them (i)", so every place that has to
/// carry a credit shows a small stock info button instead, and the button
/// opens one short sheet with all three lines (`AppleAttributionSheet`).
public enum AppleAttribution {
    public static let tmdbNotice = "This product uses the TMDB API but is not endorsed or certified by TMDB."
    public static let justWatchCredit = "Streaming availability data by JustWatch"
    public static let noContentDisclaimer = "oStream doesn't provide any content. Add your own sources."
    /// The public repository (the origin remote). It may 404 until the owner
    /// flips the repo public after a secret scan; that is expected.
    public static let sourceCodeURL = URL(string: "https://github.com/orgista/openstream-apple")!
    public static let sourceCodeDisplay = "github.com/orgista/openstream-apple"
    /// The sheet's title, and the accessibility label of every (i).
    public static let infoTitle = "Data Sources"
}

/// The TMDB logo as TMDB publishes it (unaltered, bundled so About works
/// offline), followed by its required notice. The wordmark keeps its own
/// colours: it is a third-party mark, and only OpenStream's own UI avoids blue.
struct AppleTMDBAttributionRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let logo = Self.logo {
                logo
                    .resizable()
                    .scaledToFit()
                    .frame(height: logoHeight)
                    .accessibilityLabel("TMDB")
            }
            // The notice is required in full: the tvOS sheet sizes to its
            // content and proposed one line, so the text was truncated ("…by TM…").
            Text(AppleAttribution.tmdbNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.about.tmdb")
    }

    /// Read from the copied resource folder by path: a loose PNG in a
    /// `.copy` folder is not found by `Image(_:bundle:)`.
    static let logo: Image? = {
        guard let url = Bundle.module.url(forResource: "tmdb", withExtension: "png", subdirectory: "Attribution") else {
            return nil
        }
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }()

    private var logoHeight: CGFloat {
        #if os(tvOS)
        24
        #else
        14
        #endif
    }
}

/// The small stock (i): a system-grey `info.circle` that opens
/// `AppleAttributionSheet`. Sits beside a title or a line of text.
///
/// Borderless on iOS and the Mac so a Form row it shares does not become one
/// big tappable row; plain on Apple TV so the glyph itself takes focus (the
/// owner asked for a focusable info button there, not a quiet line).
struct AppleAttributionInfoButton: View {
    @State private var showsInfo = false

    var body: some View {
        Button {
            showsInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(glyphFont)
                .foregroundStyle(.secondary)
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(.borderless)
        #endif
        .accessibilityLabel(AppleAttribution.infoTitle)
        .accessibilityIdentifier("attribution.info")
        .sheet(isPresented: $showsInfo) {
            AppleAttributionSheet()
        }
    }

    private var glyphFont: Font {
        #if os(tvOS)
        .title3
        #else
        .body
        #endif
    }
}

/// A whole settings row that opens the same sheet: "Data Sources" with the
/// (i) at its trailing edge (About; the TMDB section on Apple TV, where a
/// header cannot take focus).
struct AppleAttributionInfoRow: View {
    @State private var showsInfo = false

    var body: some View {
        Button {
            showsInfo = true
        } label: {
            #if os(tvOS)
            AppleTVNavigationLabel(AppleAttribution.infoTitle, systemImage: "info.circle")
            #else
            HStack {
                Text(AppleAttribution.infoTitle)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            // Not tinted: a Button row in a Form takes the accent colour, and
            // the About rows around it are plain label-coloured text.
            .foregroundStyle(.primary)
            #endif
        }
        .accessibilityIdentifier("settings.about.dataSources")
        .sheet(isPresented: $showsInfo) {
            AppleAttributionSheet()
        }
    }
}

/// The three lines behind every (i): TMDB's logo and notice, the JustWatch
/// credit, and the no-content statement. Stock sheet: a titled form with Done
/// on iOS and the Mac; a centred card with a Done pill on Apple TV, where a
/// sheet is an inset box without a navigation bar.
struct AppleAttributionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: AppleDesignTokens.spacingLarge) {
            Text(AppleAttribution.infoTitle)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            AppleTMDBAttributionRow()
            Text(AppleAttribution.justWatchCredit)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.about.justwatch")
            Text(AppleAttribution.noContentDisclaimer)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.about.noContent")
            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.brandSecondary)
                Spacer(minLength: 0)
            }
            .padding(.top, AppleDesignTokens.spacingSmall)
        }
        .frame(maxWidth: 900)
        .padding(AppleDesignTokens.spacingExtraLarge)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("attribution.sheet")
        #else
        NavigationStack {
            Form {
                Section {
                    AppleTMDBAttributionRow()
                }
                Section {
                    Text(AppleAttribution.justWatchCredit)
                        .accessibilityIdentifier("settings.about.justwatch")
                }
                Section {
                    Text(AppleAttribution.noContentDisclaimer)
                        .accessibilityIdentifier("settings.about.noContent")
                }
            }
            .navigationTitle(AppleAttribution.infoTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("attribution.sheet")
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
        #endif
    }
}
