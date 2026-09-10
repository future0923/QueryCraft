import SwiftUI

struct WorkspaceConnectionPickerRow: View {
    let profile: ConnectionProfile
    let endpoint: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            DatabaseBrandIcon(
                databaseProduct: profile.databaseProduct,
                isSelected: isSelected
            )
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(endpoint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help("\(profile.name) - \(endpoint)")
        .accessibilityElement(children: .combine)
    }
}
