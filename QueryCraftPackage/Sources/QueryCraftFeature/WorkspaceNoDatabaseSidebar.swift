import SwiftUI

struct WorkspaceNoDatabaseSidebar: View {
    let showDatabasePicker: @MainActor () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            Button {
                showDatabasePicker()
            } label: {
                VStack(spacing: 2) {
                    Text(
                        AppCopy.current.text(
                            "没有选择数据库",
                            "No database selected"
                        )
                    )
                    Text(
                        AppCopy.current.text(
                            "按 ⌘K 选择数据库",
                            "Press ⌘K to select a database"
                        )
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("openDatabaseButton")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
