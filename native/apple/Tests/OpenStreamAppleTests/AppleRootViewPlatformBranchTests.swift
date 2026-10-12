import Foundation
import Testing

/// Guards the defect that shipped a blank window on macOS.
///
/// `OpenStreamRootView.tabs` builds one shell per tab inside a `ForEach`, and
/// that shell used to be chosen by a *closed* `#if os(visionOS) / #elseif
/// os(iOS) / #elseif os(tvOS) / #endif` chain. macOS matched none of the three,
/// so the `ForEach` body compiled to `EmptyView`, the `TabView` was built with
/// no tabs in it, and the app opened a window whose `NSHostingView` had zero
/// subviews. It compiled cleanly and no gate caught it: the SwiftPM gate builds
/// *for* macOS, but nothing in it renders the shell.
///
/// The invariant is therefore about the shape of the source, not about any
/// value the code computes — so the test reads the source. A trailing `#else`
/// is the only shape of that chain no platform can fall out of; an `#elseif
/// os(macOS)` would pass a build today and re-open the same hole the next time
/// the package gains a platform.
@Suite("Root view platform branches")
struct AppleRootViewPlatformBranchTests {
    /// A `#if` / `#elseif` / `#else` / `#endif` chain found in the source.
    private struct Chain {
        var startLine: Int
        var conditions: [String]
        var hasElse: Bool
    }

    private static var rootViewSource: String {
        get throws {
            // …/Tests/OpenStreamAppleTests/<this file> → package root.
            let packageRoot = URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = packageRoot
                .appending(path: "Sources/OpenStreamApple/OpenStreamRootView.swift")
            return try String(contentsOf: source, encoding: .utf8)
        }
    }

    /// The lines of the `ForEach` body inside `tabs`, by brace balance.
    private static func forEachBodyLines(in source: String) -> [(number: Int, text: String)]? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("ForEach(visibleTabs)") }) else {
            return nil
        }
        var depth = 0
        var body: [(Int, String)] = []
        for index in start..<lines.count {
            let line = lines[index]
            body.append((index + 1, line))
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if index > start, depth <= 0 { return body }
        }
        return nil
    }

    private static func chains(in lines: [(number: Int, text: String)]) -> [Chain] {
        var open: [Chain] = []
        var closed: [Chain] = []
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                open.append(Chain(
                    startLine: line.number,
                    conditions: [String(trimmed.dropFirst(4))],
                    hasElse: false
                ))
            } else if trimmed.hasPrefix("#elseif "), !open.isEmpty {
                open[open.count - 1].conditions.append(String(trimmed.dropFirst(8)))
            } else if trimmed == "#else", !open.isEmpty {
                open[open.count - 1].hasElse = true
            } else if trimmed.hasPrefix("#endif"), !open.isEmpty {
                closed.append(open.removeLast())
            }
        }
        return closed
    }

    @Test("Every tab shell chain in the ForEach body has an #else")
    func tabShellChainCannotFallThrough() throws {
        let source = try Self.rootViewSource
        let body = try #require(
            Self.forEachBodyLines(in: source),
            "Could not find the ForEach(visibleTabs) body in OpenStreamRootView.swift."
        )
        let platformChains = Self.chains(in: body).filter { chain in
            chain.conditions.contains { $0.contains("os(") }
        }
        #expect(!platformChains.isEmpty, "Expected at least one per-platform chain in the tab shell.")
        for chain in platformChains {
            #expect(
                chain.hasElse,
                """
                The #if chain at OpenStreamRootView.swift:\(chain.startLine) selects a tab shell \
                per platform but has no #else, so a platform it does not name compiles to \
                EmptyView and the app opens a blank window. Conditions: \
                \(chain.conditions.joined(separator: " / "))
                """
            )
        }
    }

    @Test("The tab shell names every platform the package supports")
    func tabShellNamesEverySupportedPlatform() throws {
        let source = try Self.rootViewSource
        let body = try #require(Self.forEachBodyLines(in: source))
        let conditions = Self.chains(in: body)
            .flatMap(\.conditions)
            .joined(separator: " ")
        // macOS is the one deliberately carried by `#else` rather than named,
        // which is what stops the chain falling through.
        for platform in ["visionOS", "iOS", "tvOS"] {
            #expect(
                conditions.contains("os(\(platform))"),
                "The tab shell no longer has a branch for \(platform)."
            )
        }
    }
}
