import SwiftUI

/// The same chevron and full-list push for every home shelf.
struct AppleHomeShelf<Cards: View, Destination: View>: View {
    let title: String
    var accessory: AnyView? = nil
    var headingIdentifier = ""
    var onOpen: (() -> Void)? = nil
    var opensFullList = true
    @ViewBuilder let cards: () -> Cards
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        AppleMediaShelf(title: title, accessory: accessory, onOpen: onOpen,
                        header: onOpen == nil && opensFullList ? fullListHeader : nil,
                        headingIdentifier: headingIdentifier, content: cards)
    }

    private var fullListHeader: AnyView {
        AnyView(NavigationLink {
            destination().environment(\.appleDiscoverRows, nil)
        } label: {
            AppleShelfHeading(title: title)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(headingIdentifier))
    }
}
