#if os(macOS)
import SwiftUI

// The Mac title page's own pieces (N18). Everything below the hero that the
// iPhone also draws is in `AppleTitlePageSections.swift`; these are only the
// parts the Mac lays out differently.

/// The glyph in one of the Mac title page's round buttons (My List, Download,
/// Rate): the Mac Discover hero's 40 pt round button, so the two heroes match.
/// The surface is `AppleMacHeroButtonStyle(kind: .round)`.
struct AppleTitlePageMacRoundLabel: View {
    let title: String
    let systemImage: String
    /// A spinner in place of the glyph, while a download is being prepared.
    var showsProgress = false

    var body: some View {
        Group {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(width: AppleMacHeroLayout.listButtonSide, height: AppleMacHeroLayout.listButtonSide)
    }
}

/// One of the reference blocks at the foot of the Mac title page (A13).
enum AppleTitlePageMacReferenceBlock: Identifiable {
    case facts(title: String, facts: [AppleTitlePagePolicy.Fact], identifier: String)
    case accessibility([(badge: String, meaning: String)])

    var id: String {
        switch self {
        case .facts(_, _, let identifier): identifier
        case .accessibility: "detail.accessibility"
        }
    }

    var title: String {
        switch self {
        case .facts(let title, _, _): title
        case .accessibility: "Accessibility"
        }
    }
}

/// A reference block: its heading, then label-above-value facts or the
/// accessibility glossary. The page lays several side by side in a wide
/// window (`AppleTitlePageMacLayout.referenceColumns`).
struct AppleTitlePageMacReferenceBlockView: View {
    let block: AppleTitlePageMacReferenceBlock
    /// How many columns a facts block spreads its own facts over.
    var factColumns = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppleTitlePageSectionTitle(block.title)
            switch block {
            case .facts(_, let facts, _):
                AppleTitlePageFactList(facts: facts, columns: factColumns)
            case .accessibility(let entries):
                AppleTitlePageAccessibilityGlossary(entries: entries)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(block.id)
    }
}
#endif
