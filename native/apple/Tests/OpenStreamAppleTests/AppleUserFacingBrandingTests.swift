import Foundation
import Testing

/// App Review guideline 5.2.1: the app must not show a third party's mark.
/// "Stremio" is only a protocol name inside the code (type names, the source
/// kind's raw value, URL scheme checks); it must never reach a string a user
/// can read — UI text, accessibility labels, errors, Info.plist usage text or
/// any Localizable file.
@Suite struct AppleUserFacingBrandingTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Literals that name the protocol for matching, never for display: the
    /// bare identifier (URL scheme, saved source kind, catalog id prefix) and
    /// addresses (a DEBUG-only test catalog URL).
    private static func isAllowedIdentifier(_ literal: String) -> Bool {
        literal.lowercased() == "stremio" || literal.contains("://")
    }

    private static func files(under relative: String, extensions: Set<String>) -> [URL] {
        let root = packageRoot.appending(path: relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            extensions.contains(url.pathExtension)
                && !url.path.contains("/build/")
                && !url.path.contains(".xcodeproj/")
                && !url.path.contains("/Resources/ThirdParty")
        }
    }

    /// The string literals on one line of Swift, with `\( … )` interpolations
    /// removed (type names such as `AppleStremioPlaybackClient` are code).
    static func stringLiterals(in line: Substring) -> [String] {
        let code = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
        guard let regex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#) else { return [] }
        let text = String(code)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.map { literal in
            literal.replacingOccurrences(
                of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "", options: .regularExpression)
        }
    }

    @Test func noSwiftStringLiteralShowsTheStremioName() throws {
        var offenders: [String] = []
        for file in Self.files(under: "Sources/OpenStreamApple", extensions: ["swift"])
            + Self.files(under: "Apps", extensions: ["swift"]) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.drop { $0 == " " }
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("appleTrace(") else { continue }
                for literal in Self.stringLiterals(in: line)
                    where literal.lowercased().contains("stremio") && !Self.isAllowedIdentifier(literal) {
                    offenders.append("\(file.lastPathComponent):\(number + 1): \"\(literal)\"")
                }
            }
        }
        #expect(offenders.isEmpty, "User-visible \"Stremio\": \(offenders.joined(separator: "; "))")
    }

    @Test func noLocalizableOrPlistTextShowsTheStremioName() throws {
        let files = Self.files(under: "Sources/OpenStreamApple", extensions: ["strings", "xcstrings", "stringsdict", "plist"])
            + Self.files(under: "Apps", extensions: ["strings", "xcstrings", "stringsdict", "plist"])
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.lowercased().contains("stremio"), "\(file.lastPathComponent) names Stremio")
        }
    }

    @Test func literalScannerIgnoresInterpolatedTypeNames() {
        #expect(Self.stringLiterals(in: #"Text("Add-on \(AppleStremioThing.name(x)) ready")"#) == ["Add-on  ready"])
        #expect(Self.stringLiterals(in: #"Text("Stremio add-on") // "stremio""#) == ["Stremio add-on"])
    }
}
