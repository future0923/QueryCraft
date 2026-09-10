import SwiftUI

struct LicenseStatusLabel: View {
    let title: String
    let systemImage: String
    let iconColor: Color

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
        }
        .font(.subheadline)
        .fixedSize()
    }
}
