import SwiftUI

/// The in-app third-party notices screen.
@MainActor
struct AppleThirdPartyNoticesView: View {
    var body: some View {
        AppleSettingsCollection {
            Section {
                #if os(tvOS)
                LabeledContent("Source Code", value: AppleAttribution.sourceCodeURL.absoluteString)
                    .accessibilityIdentifier("settings.acknowledgements.sourceCode")
                #else
                Link("Source Code", destination: AppleAttribution.sourceCodeURL)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings.acknowledgements.sourceCode")
                #endif
            }
            Section {
                ForEach(AppleThirdPartyNotices.all()) { notice in
                    NavigationLink {
                        AppleThirdPartyNoticeDetailView(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.name)
                                .foregroundStyle(.primary)
                            Text(notice.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.acknowledgements.\(notice.id)")
                }
            }
        }
        .appleSettingsPage("Acknowledgements")
        .scrollIndicators(.hidden)
    }
}

@MainActor
private struct AppleThirdPartyNoticeDetailView: View {
    let notice: AppleThirdPartyNotice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(notice.name)
                    .font(.headline)
                Text(notice.license)
                    .foregroundStyle(.secondary)
                if let url = URL(string: notice.url) {
                    #if os(tvOS)
                    Text(url.absoluteString)
                        .font(.caption)
                    #else
                    Link(notice.url, destination: url)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    #endif
                }
                if !notice.note.isEmpty {
                    Text(notice.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(notice.text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.acknowledgements.license")
                    #if os(tvOS)
                    .focusable()
                    #endif
            }
            .padding()
        }
        .appleSettingsPage(notice.name)
        .scrollIndicators(.hidden)
    }
}
