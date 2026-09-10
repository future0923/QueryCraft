import SwiftUI

struct DatabaseBrandIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    private let presentation: DatabaseBrandPresentation
    private let isSelected: Bool

    init(
        databaseType: DatabaseType,
        isSelected: Bool = false
    ) {
        presentation = databaseType.brandPresentation
        self.isSelected = isSelected
    }

    init(
        databaseProduct: DatabaseProduct,
        isSelected: Bool = false
    ) {
        presentation = databaseProduct.brandPresentation
        self.isSelected = isSelected
    }

    var body: some View {
        Image(presentation.assetName, bundle: .module)
            .renderingMode(isSelected ? .template : .original)
            .resizable()
            .scaledToFit()
            .scaleEffect(presentation.opticalScale)
            .brightness(
                colorScheme == .dark
                    ? presentation.darkModeBrightness
                    : 0
            )
            .contrast(presentation.contrast)
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}
