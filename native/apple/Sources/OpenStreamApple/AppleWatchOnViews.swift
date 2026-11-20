import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Opens a Watch on link. `appOnly` succeeds only when an installed app
/// claims the link (universal links), so a missing app reports false instead
/// of failing silently; otherwise the system decides (the TV app for
/// tv.apple.com, a browser for the web).
@MainActor
func appleOpenWatchOnURL(_ url: URL, appOnly: Bool) async -> Bool {
    #if canImport(UIKit)
    return await UIApplication.shared.open(url, options: appOnly ? [.universalLinksOnly: true] : [:])
    #elseif canImport(AppKit)
    return NSWorkspace.shared.open(url)
    #else
    return false
    #endif
}

/// "Open Netflix and search for …", for when nothing could be opened.
struct AppleWatchOnInstructions: Identifiable, Equatable {
    let service: AppleStreamingService
    let title: String
    /// The web page for the title, shown as a QR code on the Apple TV.
    let link: AppleWatchOnLink?

    var id: String { "\(service.rawValue):\(title)" }
    var message: String { "Open \(service.displayName) and search for “\(title)”" }
}

struct AppleWatchOnInstructionsView: View {
    let instructions: AppleWatchOnInstructions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 32) {
            Text(instructions.message)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("detail.watchOn.instructions")
            #if os(tvOS)
            if let url = instructions.link?.url {
                AppleWatchOnQRCode(url: url, service: instructions.service)
            }
            #endif
            Button("Done") { dismiss() }
                .accessibilityIdentifier("detail.watchOn.instructions.done")
        }
        .padding(48)
        .frame(maxWidth: 900)
    }
}

#if os(tvOS)
/// The title's web page as a QR code, to open it on a phone.
private struct AppleWatchOnQRCode: View {
    let url: URL
    let service: AppleStreamingService

    var body: some View {
        if let image = Self.image(for: url) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding()
                .background(.white, in: .rect(cornerRadius: 16))
                .frame(width: 320, height: 320)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("QR code for the \(service.displayName) page")
        }
    }

    private static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 12, y: 12)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Apple TV's "Watch on…": a pushed page of services rather than a dialog,
/// as the download options are (a tvOS dialog drew focused rows white on
/// white, N73). Menu pops it.
struct AppleTVWatchOnPage: View {
    let choices: [AppleWatchOnChoice]
    let onChoose: (AppleWatchOnChoice) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(choices) { choice in
                    Button {
                        onChoose(choice)
                    } label: {
                        AppleTVFocusReadableText(choice.service.displayName)
                    }
                    .accessibilityLabel(choice.title)
                    .accessibilityIdentifier("detail.watchOn.\(choice.id)")
                }
            }
        }
        .appleSettingsPage("Watch on…")
    }
}
#endif
