import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceDatabaseSchemaIndexColumnsPopoverModel {
    var columns: [WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition] = []
    var availableColumnNames: [String] = []
    var accessibilityTitle = ""
    var supportsPrefixLength = true
    var supportsDirection = true

    func prepare(
        columns: [WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition],
        availableColumnNames: [String],
        accessibilityTitle: String,
        supportsPrefixLength: Bool,
        supportsDirection: Bool
    ) {
        self.columns = columns
        self.availableColumnNames = availableColumnNames
        self.accessibilityTitle = accessibilityTitle
        self.supportsPrefixLength = supportsPrefixLength
        self.supportsDirection = supportsDirection
    }
}

struct WorkspaceDatabaseSchemaIndexColumnsPopover: View {
    @Bindable var model: WorkspaceDatabaseSchemaIndexColumnsPopoverModel
    let update: @MainActor (
        [WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition]
    ) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.current.text("索引字段", "Index Columns"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.columns) { column in
                        columnRow(column)
                    }
                }
                .padding(10)
            }

            Divider()

            HStack {
                WorkspaceInlineIconButton(
                    systemImageName: "plus",
                    title: AppCopy.current.text(
                        "添加索引字段",
                        "Add Index Column"
                    )
                ) {
                    mutate { columns in
                        columns.append(
                            .init(name: model.availableColumnNames.first ?? "")
                        )
                    }
                }

                Spacer()

                Text(
                    AppCopy.current.text(
                        "从上到下决定联合索引顺序",
                        "Top-to-bottom order defines the composite index"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: 480, height: 330)
        .accessibilityLabel(model.accessibilityTitle)
    }

    private func columnRow(
        _ column: WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition
    ) -> some View {
        let binding = binding(for: column)
        let index = model.columns.firstIndex(where: { $0.id == column.id }) ?? 0
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            WorkspaceDatabaseSchemaOptionPicker(
                selection: binding.name,
                options: WorkspaceDatabaseSchemaChoiceCatalog.columnNames(
                    model.availableColumnNames
                ),
                placeholder: AppCopy.current.text("选择字段", "Select Column"),
                accessibilityTitle: AppCopy.current.text(
                    "索引字段",
                    "Index Column"
                )
            )
            .frame(minWidth: 150, maxWidth: .infinity)

            if model.supportsPrefixLength {
                WorkspaceDatabaseSchemaInspectorPickerField {
                    TextField(
                        AppCopy.current.text("前缀", "Prefix"),
                        text: binding.prefixLength
                    )
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .monospaced))
                }
                .frame(width: 64)
                .help(
                    AppCopy.current.text(
                        "可选的索引前缀长度",
                        "Optional index prefix length"
                    )
                )
            }

            if model.supportsDirection {
                WorkspaceDatabaseSchemaOptionPicker(
                    selection: Binding(
                        get: { binding.wrappedValue.isDescending ? "desc" : "asc" },
                        set: { binding.wrappedValue.isDescending = $0 == "desc" }
                    ),
                    options: [
                        .init(value: "asc", title: "asc"),
                        .init(value: "desc", title: "desc"),
                    ],
                    placeholder: "asc",
                    accessibilityTitle: AppCopy.current.text("排序方向", "Direction"),
                    usesSearch: false
                )
                .frame(width: 58)
            }

            WorkspaceInlineIconButton(
                systemImageName: "arrow.up",
                title: AppCopy.current.text("上移", "Move Up"),
                isEnabled: index > 0
            ) {
                move(column.id, by: -1)
            }

            WorkspaceInlineIconButton(
                systemImageName: "arrow.down",
                title: AppCopy.current.text("下移", "Move Down"),
                isEnabled: index < model.columns.count - 1
            ) {
                move(column.id, by: 1)
            }

            WorkspaceInlineIconButton(
                systemImageName: "minus",
                title: AppCopy.current.text(
                    "移除索引字段",
                    "Remove Index Column"
                ),
                isEnabled: model.columns.count > 1
            ) {
                mutate { $0.removeAll { $0.id == column.id } }
            }
        }
    }

    private func binding(
        for column: WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition
    ) -> Binding<WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition> {
        Binding(
            get: {
                model.columns.first(where: { $0.id == column.id }) ?? column
            },
            set: { updated in
                mutate { columns in
                    guard let index = columns.firstIndex(where: {
                        $0.id == column.id
                    }) else { return }
                    columns[index] = updated
                }
            }
        )
    }

    private func move(_ id: UUID, by offset: Int) {
        mutate { columns in
            guard let source = columns.firstIndex(where: { $0.id == id }) else {
                return
            }
            let destination = source + offset
            guard columns.indices.contains(destination) else { return }
            columns.swapAt(source, destination)
        }
    }

    private func mutate(
        _ mutation: (inout [WorkspaceDatabaseSchemaEditorState
            .IndexColumnDefinition]) -> Void
    ) {
        var columns = model.columns
        mutation(&columns)
        model.columns = columns
        update(columns)
    }
}
