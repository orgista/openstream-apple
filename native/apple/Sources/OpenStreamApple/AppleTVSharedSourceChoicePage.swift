import SwiftUI

#if os(tvOS)
/// Apple TV's "Choose the source for this channel": a pushed page of readable
/// rows instead of the confirmationDialog the other platforms keep. On tvOS
/// that dialog drew its focused choice white on the white focus fill (N72
/// capture), the same trap the Discover Rows Move dialog had (N71b). A row
/// starts the channel from that source; Leave SharePlay, or Menu, leaves.
struct AppleTVSharedSourceChoicePage: View {
    let choices: [AppleSharedChannelSourceChoice]
    let onChoose: (AppleIPTVChannel) -> Void
    let onLeave: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    Button {
                        onChoose(choice.channel)
                    } label: {
                        AppleTVFocusReadableText(choice.title,
                                                 isDestructive: AppleSharedSourcePromptAction.choose(choice).isDestructive)
                    }
                    .accessibilityIdentifier("live.shareplay.source.\(index)")
                }
            }
            Section {
                Button(action: onLeave) {
                    AppleTVFocusReadableText(AppleSharedSourcePromptAction.leave.title,
                                             isDestructive: AppleSharedSourcePromptAction.leave.isDestructive)
                }
                .accessibilityIdentifier("live.shareplay.leave")
            }
        }
        .appleSettingsPage("Choose the source for this channel")
    }
}
#endif
