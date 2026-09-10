import SwiftUI

struct DatabaseDriverSelectionRow: View {
    let item: DatabaseProductCatalogItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            DatabaseBrandIcon(
                databaseProduct: item.entry.databaseProduct,
                isSelected: isSelected
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.displayName)
                    .font(.headline)
                Text(item.entry.databaseProduct.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            DatabaseDriverInstallationStatusView(
                state: item.installationState
            )
        }
        .padding(.vertical, 5)
    }
}
