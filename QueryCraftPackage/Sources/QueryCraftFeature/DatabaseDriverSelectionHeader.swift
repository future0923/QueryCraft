import SwiftUI

struct DatabaseDriverSelectionHeader: View {
    @Binding var searchText: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.current.text("选择连接类型", "Choose Connection Type"))
                    .font(.title2)
                    .bold()
                Text(
                    AppCopy.current.text(
                        "选择要创建的连接类型。",
                        "Choose the type of connection to create."
                    )
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(
                AppCopy.current.text("搜索", "Search"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .accessibilityIdentifier("databaseDriverSearchField")
        }
        .padding(24)
    }
}
