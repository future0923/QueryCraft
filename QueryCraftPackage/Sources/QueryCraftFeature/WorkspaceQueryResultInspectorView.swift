import SwiftUI

struct WorkspaceQueryResultInspectorView: View {
    let context: WorkspaceQueryResultInspectorContext
    let searchText: String

    var body: some View {
        if context.isLoading {
            ProgressView(
                AppCopy.current.text(
                    "正在加载结果行…",
                    "Loading result row..."
                )
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fields = context.dataFields {
            WorkspaceDatabaseInspectorRowView(
                fields: fields,
                searchText: searchText,
                isUpdatingLoadedValue: context.isUpdatingValue,
                applyMutation: context.applyMutation
            )
        } else if let fields = context.fields {
            fieldList(fields)
        } else {
            ContentUnavailableView(
                AppCopy.current.text(
                    "未选择结果行",
                    "No Result Row Selected"
                ),
                systemImage: "tablecells",
                description: Text(
                    AppCopy.current.text(
                        "请选择一个结果单元格或行以查看值。",
                        "Select a result cell or row to inspect its values."
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fieldList(
        _ fields: [WorkspaceQueryResultInspectorField]
    ) -> some View {
        let filteredFields =
            searchText.isEmpty
            ? fields
            : fields.filter {
                $0.name.localizedStandardContains(searchText)
                    || $0.type.localizedStandardContains(searchText)
                    || $0.searchPreview.localizedStandardContains(searchText)
            }

        return List {
            Section {
                if filteredFields.isEmpty && !searchText.isEmpty {
                    Text(
                        AppCopy.current.text(
                            "没有匹配的字段",
                            "No matching fields"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredFields) { field in
                        WorkspaceQueryResultInspectorFieldRow(field: field)
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                HStack {
                    Text(AppCopy.current.text("结果字段", "Result Fields"))
                    Spacer()
                    Text("\(filteredFields.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}
