import SwiftUI

struct WorkspacePostgreSQLSchemaFooter: View {
    let schemas: [String]
    let selectedSchema: String?
    let selectSchema: (String) -> Void
    let addTable: @MainActor () -> Void

    private var selection: Binding<String> {
        Binding(
            get: { selectedSchema ?? "" },
            set: { selectSchema($0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceInlineIconButton(
                systemImageName: "plus",
                title: AppCopy.current.text("新增表", "New Table"),
                action: addTable
            )
            .accessibilityIdentifier("newTableButton")

            Spacer(minLength: 0)

            if selectedSchema != nil {
                Picker(
                    AppCopy.current.text("Schema", "Schema"),
                    selection: selection
                ) {
                    ForEach(schemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(
                    AppCopy.current.text(
                        "切换 Schema",
                        "Switch Schema"
                    )
                )
                .accessibilityIdentifier("postgresqlSchemaPicker")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        AppCopy.current.text(
                            "正在加载 Schema",
                            "Loading Schemas"
                        )
                    )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .accessibilityIdentifier("databaseObjectFooter")
    }
}
