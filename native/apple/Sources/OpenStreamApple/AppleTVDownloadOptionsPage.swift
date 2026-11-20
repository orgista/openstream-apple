import SwiftUI

#if os(tvOS)
/// Apple TV's "Download Options" and "Season Download Options": a pushed page
/// of readable rows instead of the confirmationDialog the other platforms
/// keep. On tvOS that dialog drew a focused non-destructive choice (Pause,
/// Resume) white on the white focus fill (N73 capture), the trap N71b and N72
/// fixed the same way. Menu pops it, as the dialog's Cancel did.
struct AppleTVDownloadOptionsPage: View {
    let title: String
    let message: String
    let choices: [AppleDownloadOptionChoice]
    let onChoose: (AppleDownloadOptionChoice) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(choices) { choice in
                    Button {
                        onChoose(choice)
                    } label: {
                        AppleTVFocusReadableText(choice.title, isDestructive: choice.isDestructive)
                    }
                    .accessibilityIdentifier("detail.download.option.\(choice.id)")
                }
            } footer: {
                Text(message)
            }
        }
        .appleSettingsPage(title)
    }
}
#endif
