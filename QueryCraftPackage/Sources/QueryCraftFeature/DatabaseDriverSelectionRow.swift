import SwiftUI

struct DatabaseDriverSelectionRow: View {
    let item: DatabaseProductCatalogItem
    let isSelected: Bool

    var body: some View {
        ConnectionTypeSelectionRow(title: item.entry.displayName, subtitle: item.entry.databaseProduct.tagline,
            state: item.installationState) {
                DatabaseBrandIcon(databaseProduct: item.entry.databaseProduct, isSelected: isSelected)
            }
    }
}

struct ConnectionTypeSelectionRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let state: DatabaseDriverInstallationState
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            icon().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            DatabaseDriverInstallationStatusView(state: state)
        }.padding(.vertical, 5)
    }
}
