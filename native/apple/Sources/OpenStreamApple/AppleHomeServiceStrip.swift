import SwiftUI

struct AppleHomeServiceStrip<Destination: View>: View {
    let title: String
    let services: [AppleHomeServices.Service]
    let customNames: [String: String]
    @ViewBuilder let destination: (AppleStreamingService) -> Destination
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var buttonSize: CGSize {
        AppleHomeServiceLayout.buttonSize(regularWidth: horizontalSizeClass != .compact)
    }

    private var labelFont: Font {
        #if os(tvOS)
        .system(size: 31, weight: .semibold)
        #else
        horizontalSizeClass != .compact ? .headline : .subheadline.weight(.semibold)
        #endif
    }

    var body: some View {
        AppleMediaShelf(title: title, headingIdentifier: "home.services.heading", focusItemIDs: services.map(\.id)) {
            ForEach(services) { service in
                NavigationLink { destination(service.service) } label: {
                    Text(service.title(customNames: customNames))
                        .font(labelFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                #if !os(tvOS)
                .tint(.gray)
                .foregroundStyle(.primary)
                #endif
                .frame(width: buttonSize.width, height: buttonSize.height)
                .appleShelfFocusItem(id: service.id)
                .accessibilityIdentifier("home.service.\(service.id)")
            }
        }
    }
}
