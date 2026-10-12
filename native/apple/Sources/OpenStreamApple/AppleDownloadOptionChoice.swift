import Foundation

/// One choice in a title page's "Download Options" or "Season Download
/// Options" prompt. Every platform shows the same choices, in this order: the
/// dialog on iPhone, iPad, Mac and Vision Pro, a pushed page of readable rows
/// on Apple TV (whose dialog drew the focused choice white on white, N73).
enum AppleDownloadOptionChoice: String, CaseIterable, Identifiable, Sendable {
    case pause
    case resume
    case cancelDownload
    case cancelSeasonDownload

    var id: String { rawValue }

    /// Named for what it cancels. A confirmation dialog always carries its own
    /// Cancel, so "Cancel" here gave the viewer two buttons with one word
    /// between them and no way to tell which one stopped the download (button
    /// crawl, 2026-09-19).
    var title: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .cancelDownload: "Cancel Download"
        case .cancelSeasonDownload: "Cancel Season Download"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .pause, .resume: false
        case .cancelDownload, .cancelSeasonDownload: true
        }
    }

    /// The choices for the title's download (`season == false`) or for the
    /// running season download. Pause only while bytes are moving and the
    /// download can resume; Resume only while paused; the title's Cancel only
    /// while a download is owned; the season's Cancel always.
    static func choices(
        for state: AppleOfflineDownloadCoordinator.State,
        supportsPauseResume: Bool,
        season: Bool
    ) -> [AppleDownloadOptionChoice] {
        var choices: [AppleDownloadOptionChoice] = []
        switch state {
        case .downloading where supportsPauseResume:
            choices.append(.pause)
        case .paused:
            choices.append(.resume)
        default:
            break
        }
        if season {
            choices.append(.cancelSeasonDownload)
        } else if state.ownsDownload {
            choices.append(.cancelDownload)
        }
        return choices
    }
}
