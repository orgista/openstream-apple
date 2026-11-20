import SwiftUI

struct AppleGuideTimeOffsetSection: View {
    let sourceID: UUID
    let settings: AppleSettingsStore
    @State private var offset = 0

    var body: some View {
        Section("Guide") {
            #if os(tvOS)
            AppleTVChoicePicker("Guide time offset", selection: $offset, options: (-12...14).map { hours in
                .init(value: hours, title: hours == 0 ? "0 h" : String(format: "%+d h", hours))
            })
            .accessibilityIdentifier("source.guide.timeOffset")
            #else
            Picker("Guide time offset", selection: $offset) {
                ForEach(-12...14, id: \.self) { hours in
                    Text(hours == 0 ? "0 h" : String(format: "%+d h", hours)).tag(hours)
                }
            }
            .accessibilityIdentifier("source.guide.timeOffset")
            #endif
        }
        .onAppear { offset = settings.guideTimeOffsets[sourceID.uuidString] ?? 0 }
        .onChange(of: offset) { _, value in settings.guideTimeOffsets[sourceID.uuidString] = value }
    }
}
