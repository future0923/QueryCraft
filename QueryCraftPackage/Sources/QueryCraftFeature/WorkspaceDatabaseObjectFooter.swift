import SwiftUI

struct WorkspaceDatabaseObjectFooter: View {
    let tableCount: Int
    let addTable: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceInlineIconButton(
                systemImageName: "plus",
                title: AppCopy.current.text("新增表", "New Table"),
                action: addTable
            )
            .accessibilityIdentifier("newTableButton")

            Spacer(minLength: 0)

            Text(
                AppCopy.current.text(
                    "共 \(tableCount) 张表",
                    "\(tableCount) tables"
                )
            )
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .accessibilityIdentifier("databaseObjectFooter")
    }
}
