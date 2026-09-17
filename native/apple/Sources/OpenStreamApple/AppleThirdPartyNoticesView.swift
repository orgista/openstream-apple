import SwiftUI

/// The in-app third-party notices screen.
@MainActor
struct AppleThirdPartyNoticesView: View {
    var body: some View {
        List {
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
                            if let url = URL(string: notice.url) {
                                Link(notice.url, destination: url)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .appleSettingsPage("Third-Party Notices")
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
                    Link(notice.url, destination: url)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Text(notice.text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .appleSettingsPage(notice.name)
        .scrollIndicators(.hidden)
    }
}
