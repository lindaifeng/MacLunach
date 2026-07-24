import SwiftUI

struct BrandLogoView: View {
    let size: CGFloat

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("一念品牌标志")
    }
}
