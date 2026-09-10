import SwiftUI

struct DatabaseDriverSelectionHeader: View {
    @Binding var searchText: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.current.text("选择数据库", "Choose Database"))
                    .font(.title2)
                    .bold()
                Text(
                    AppCopy.current.text(
                        "选择要连接的数据库类型。",
                        "Choose the type of database to connect to."
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
