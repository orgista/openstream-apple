import SwiftUI

/// The previous decoded still stays visible until a replacement has decoded.
struct AppleTitlePageDecodedSlotImage: View {
    let image: CGImage
    let art: AppleTitlePageSlotArt
    let slotHeight: CGFloat

    var body: some View {
        ZStack {
            if art.isPosterCard {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .blur(radius: 30).overlay(Color.black.opacity(0.35))
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: max(0, slotHeight - 24) * 2 / 3, height: max(0, slotHeight - 24))
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
    }
}
