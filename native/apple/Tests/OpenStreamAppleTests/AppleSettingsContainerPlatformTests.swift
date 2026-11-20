import Foundation
import Testing

/// Guards the defect that made nine macOS settings pages read as blank.
///
/// `AppleSettingsContentModifier` chooses a layout per platform. Its `#else`
/// arm was written for "everything that is not visionOS, iOS or tvOS" and did
/// the one thing macOS cannot take: it capped the width and passed the height
/// proposal straight through. A macOS `Form` defaults to `.columns`, which has
/// no scroll view and therefore an *intrinsic* height, so the form stayed as
/// short as its own rows and was laid out from the bottom of the window up. A
/// Trakt pane is two fields tall; at the 900x450 default it was entirely below
/// the window edge. About, Privacy, Backup, Metadata, Storage, Watch
/// Providers, Add Catalog and Web Management all failed the same way, from
/// this one branch.
///
/// Like `AppleRootViewPlatformBranchTests`, the invariant is about the shape of
/// the source rather than a value the code computes, so the test reads the
/// source. It is the same bug class both times: a platform quietly taking a
/// branch that was not written for it.
@Suite("Settings container platform branches")
struct AppleSettingsContainerPlatformTests {
    private static func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// The body of `AppleSettingsContentModifier.body(content:)`, by brace
    /// balance from the declaration.
    private static func modifierBody(in source: String) -> [String]? {
        let lines = source.components(separatedBy: "\n")
        guard let declaration = lines.firstIndex(where: {
            $0.contains("struct AppleSettingsContentModifier")
        }) else { return nil }
        guard let start = lines[declaration...].firstIndex(where: {
            $0.contains("func body(content: Content)")
        }) else { return nil }
        var depth = 0
        var body: [String] = []
        for index in start..<lines.count {
            body.append(lines[index])
            depth += lines[index].filter { $0 == "{" }.count
            depth -= lines[index].filter { $0 == "}" }.count
            if index > start, depth <= 0 { return body }
        }
        return nil
    }

    @Test("macOS has a branch of its own, not the trailing #else")
    func macOSIsNamedExplicitly() throws {
        let body = try #require(
            Self.modifierBody(in: try Self.source("Sources/OpenStreamApple/AppleDesignTokens.swift")),
            "Could not find AppleSettingsContentModifier.body in AppleDesignTokens.swift."
        )
        #expect(
            body.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#elseif os(macOS)") },
            """
            The settings container no longer names macOS. It will fall into the trailing #else, \
            which caps the width and proposes no height — the shape that laid every Form-based \
            settings page out from the bottom of the window and made nine of them read as blank.
            """
        )
    }

    /// `.grouped` is the whole fix: a scrollable, top-anchored inset list with
    /// chevrons on its navigation rows, which fills the height it is given.
    /// Without it macOS gets `.columns` — right-aligned labels in a narrow
    /// centre column and navigation links drawn as bordered capsule buttons.
    @Test("The macOS branch sets the grouped form style and fills the height")
    func macOSBranchUsesGroupedFormStyle() throws {
        let body = try #require(
            Self.modifierBody(in: try Self.source("Sources/OpenStreamApple/AppleDesignTokens.swift"))
        )
        guard let start = body.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#elseif os(macOS)")
        }) else {
            Issue.record("No macOS branch to check.")
            return
        }
        let end = body[(start + 1)...].firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") || trimmed.hasPrefix("#endif")
        }) ?? body.endIndex
        let branch = body[start..<end].joined(separator: "\n")
        #expect(branch.contains(".formStyle(.grouped)"))
        #expect(branch.contains("maxHeight: .infinity"),
                "Without a height proposal the pane is laid out at its intrinsic height again.")
    }

    /// Every `#if` chain in the modifier must end in `#else`, so no future
    /// platform can fall through it the way macOS did — the same invariant the
    /// root view's tab shell carries.
    @Test("Every platform chain in the modifier ends in #else")
    func modifierChainsCannotFallThrough() throws {
        let body = try #require(
            Self.modifierBody(in: try Self.source("Sources/OpenStreamApple/AppleDesignTokens.swift"))
        )
        var depth = 0
        var sawElse = false
        var sawPlatform = false
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                depth += 1
                sawPlatform = sawPlatform || trimmed.contains("os(")
            } else if trimmed == "#else", depth == 1 {
                sawElse = true
            } else if trimmed.hasPrefix("#endif") {
                depth -= 1
            }
        }
        #expect(sawPlatform, "Expected a per-platform chain in the settings container.")
        #expect(sawElse, "The settings container's platform chain has no #else to catch a new platform.")
    }
}
