import SwiftUI

struct ConnectionProfileRow: View {
    let profile: ConnectionProfile
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            DatabaseBrandIcon(
                databaseProduct: profile.databaseProduct,
                isSelected: isSelected
            )
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.body)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim:
                    "\(profile.username) @ \(profile.host):\(profile.port)"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(
                        "\(profile.username)@\(profile.host):\(profile.port)"
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.name)
    }
}
