import Foundation

/// One entry in the in-app third-party notices screen.
public struct AppleThirdPartyNotice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let license: String
    public let url: String
    public let text: String
}

/// The bundled third-party notices shipped with the app.
public enum AppleThirdPartyNotices {
    /// Kept for source compatibility with older clients. The screen lists the
    /// source link alongside each component instead of using a footer paragraph.
    public static let sourceOffer: String = "Source links are listed for each component."

    /// One entry per bundled license file, sorted by name.
    public static func all() -> [AppleThirdPartyNotice] {
        let entries: [(name: String, license: String, url: String)] = [
            ("AetherEngine", "LGPL-3.0 + App Store exception", "https://github.com/superuser404notfound/AetherEngine"),
            ("FFmpeg", "LGPL-2.1-or-later", "https://github.com/superuser404notfound/FFmpegBuild"),
            ("dav1d", "BSD-2-Clause", "https://github.com/superuser404notfound/FFmpegBuild"),
            ("libdovi", "MIT", "https://github.com/superuser404notfound/LibDovi"),
            ("libzvbi", "LGPL-2.1 + MIT", "https://github.com/superuser404notfound/FFmpegBuild"),
            ("zimg", "WTFPL", "https://github.com/superuser404notfound/FFmpegBuild"),
        ]
        return entries
            .compactMap { entry in
                guard
                    let fileURL = Bundle.module.url(
                        forResource: entry.name,
                        withExtension: "txt",
                        subdirectory: "ThirdPartyNotices"
                    ),
                    let text = try? String(contentsOf: fileURL, encoding: .utf8),
                    !text.isEmpty
                else { return nil }
                return AppleThirdPartyNotice(
                    id: entry.name,
                    name: entry.name,
                    license: entry.license,
                    url: entry.url,
                    text: text
                )
            }
            .sorted { $0.name < $1.name }
    }
}
