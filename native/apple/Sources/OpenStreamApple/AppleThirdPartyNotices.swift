import Foundation

/// One entry in the in-app third-party notices screen.
public struct AppleThirdPartyNotice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let license: String
    public let url: String
    /// One line below the source link: a fork, a build, a bundled component.
    public let note: String
    public let text: String
}

/// The bundled third-party notices shipped with the app. Every component
/// that reaches a shipped binary is listed here with its license text, read
/// from `Resources/ThirdPartyNotices/<name>.txt`; `ThirdPartyLicenses/NOTICE.txt`
/// is the same list as one plain-text file.
public enum AppleThirdPartyNotices {
    /// Kept for source compatibility with older clients. The screen lists the
    /// source link alongside each component instead of using a footer paragraph.
    public static let sourceOffer: String = "Source links are listed for each component."

    /// OpenStream's fork of the engine, where its own changes are published.
    public static let aetherEngineForkURL = "https://github.com/cyberbanksy/AetherEngine"

    /// One entry per bundled license file, sorted by name.
    public static func all() -> [AppleThirdPartyNotice] {
        let entries: [(name: String, license: String, url: String, note: String)] = [
            ("AetherEngine", "LGPL-3.0 + App Store / DRM exception",
             "https://github.com/superuser404notfound/AetherEngine",
             "Playback engine, release 6.66.0, linked as dynamic frameworks. OpenStream's fork with its changes: \(aetherEngineForkURL)"),
            ("AMSMB2", "LGPL-2.1 (with libsmb2)",
             "https://github.com/amosavian/AMSMB2",
             "SMB client for network shares on iOS, tvOS and macOS; statically includes libsmb2 (https://github.com/sahlberg/libsmb2)."),
            ("FFmpeg", "LGPL-2.1-or-later",
             "https://github.com/superuser404notfound/FFmpegBuild",
             "libavcodec, libavformat, libavutil, libswresample, libswscale and libavfilter from https://ffmpeg.org, built by FFmpegBuild without --enable-gpl or --enable-version3 and linked dynamically."),
            ("dav1d", "BSD-2-Clause",
             "https://github.com/superuser404notfound/FFmpegBuild",
             "AV1 decoder (https://code.videolan.org/videolan/dav1d), bundled by FFmpegBuild."),
            ("libdovi", "MIT",
             "https://github.com/superuser404notfound/LibDovi",
             "The dolby_vision crate of quietvoid's dovi_tool (https://github.com/quietvoid/dovi_tool), MIT OR Apache-2.0, used under MIT."),
            ("libzvbi", "LGPL-2.1 + MIT",
             "https://github.com/superuser404notfound/FFmpegBuild",
             "Teletext decoder, bundled by FFmpegBuild; its GPL-only files are removed in FFmpegBuild's build.sh."),
            ("zimg", "WTFPL",
             "https://github.com/superuser404notfound/FFmpegBuild",
             "Scaling and colorspace library (https://github.com/sekrit-twc/zimg), bundled by FFmpegBuild."),
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
                    note: entry.note,
                    text: text
                )
            }
            .sorted { $0.name < $1.name }
    }
}
