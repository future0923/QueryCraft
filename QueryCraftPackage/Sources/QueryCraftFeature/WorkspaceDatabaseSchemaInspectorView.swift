import SwiftUI

struct WorkspaceDatabaseSchemaInspectorView: View {
    let context: WorkspaceDatabaseSchemaInspectorContext
    let searchText: String

    var body: some View {
        Group {
            switch context.item {
            case .column(let item):
                columnForm(item)
            case .index(let item):
                indexForm(item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func columnForm(
        _ item: WorkspaceDatabaseSchemaEditorState.ColumnItem
    ) -> some View {
        let definition = columnBinding(item)
        return List {
            Section(AppCopy.current.text("字段", "COLUMN")) {
                if context.descriptor.includesColumn(.name)
                    && matches(AppCopy.current.text("名称", "Name")) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("名称", "Name")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            TextField("", text: definition.name)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                    }
                }
                if context.descriptor.includesColumn(.type)
                    && matches(AppCopy.current.text("类型", "Type")) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("类型", "Type")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: definition.type,
                                options: context.descriptor.columnTypes.map {
                                    .init(value: $0, title: $0)
                                },
                                placeholder: AppCopy.current.text(
                                    "选择类型",
                                    "Select Type"
                                ),
                                accessibilityTitle: AppCopy.current.text(
                                    "字段类型",
                                    "Column Type"
                                ),
                                allowsCustomValue: true,
                                usesMonospacedFont: true
                            )
                        }
                    }
                }
                if context.descriptor.includesColumn(.characterSet)
                    && matches(AppCopy.current.text("字符集", "Character Set")) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("字符集", "Character Set")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: characterSetBinding(definition),
                                options: WorkspaceDatabaseSchemaChoiceCatalog
                                    .characterSets(context.schemaChoices),
                                placeholder: "default",
                                accessibilityTitle: AppCopy.current.text(
                                    "字符集",
                                    "Character Set"
                                ),
                                allowsCustomValue: true,
                                usesMonospacedFont: true
                            )
                        }
                    }
                    .disabled(
                        !definition.wrappedValue
                            .supportsCharacterSetAndCollation
                    )
                    .help(characterOptionsHelp)
                }
                if context.descriptor.includesColumn(.collation)
                    && matches(AppCopy.current.text("排序规则", "Collation")) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("排序规则", "Collation")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: collationBinding(definition),
                                options: WorkspaceDatabaseSchemaChoiceCatalog
                                    .collations(
                                        context.schemaChoices,
                                        characterSet: definition.wrappedValue
                                            .characterSet
                                    ),
                                placeholder: "default",
                                accessibilityTitle: AppCopy.current.text(
                                    "排序规则",
                                    "Collation"
                                ),
                                allowsCustomValue: true
                            )
                        }
                    }
                    .disabled(
                        !definition.wrappedValue
                            .supportsCharacterSetAndCollation
                    )
                    .help(characterOptionsHelp)
                }
            }

            Section(AppCopy.current.text("约束", "CONSTRAINTS")) {
                if context.descriptor.includesColumn(.primaryKey) {
                    Toggle(
                        AppCopy.current.text("主键", "Primary Key"),
                        isOn: Binding(
                            get: { context.isPrimaryKey },
                            set: { context.setPrimaryKey(item.id, $0) }
                        )
                    )
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .listRowSeparator(.hidden)
                }
                if context.descriptor.includesColumn(.nullable) {
                    Toggle(
                        AppCopy.current.text("允许 NULL", "Allow NULL"),
                        isOn: definition.isNullable
                    )
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .listRowSeparator(.hidden)
                    .disabled(item.definition.isGenerated || context.isPrimaryKey)
                    .help(
                        context.isPrimaryKey
                            ? primaryKeyNullabilityHelp
                            : generatedNullabilityHelp
                    )
                }
                if context.descriptor.includesColumn(.automaticValue),
                   let automaticValueStyle = context.descriptor.automaticValueStyle {
                    Toggle(
                        automaticValueStyle == .identity
                            ? AppCopy.current.text("标识列", "Identity")
                            : AppCopy.current.text("自动递增", "Auto Increment"),
                        isOn: definition.isAutoIncrement
                    )
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .listRowSeparator(.hidden)
                    .disabled(item.definition.isGenerated)
                    .help(generatedConflictHelp)
                }
                if context.descriptor.supportsColumnVisibility {
                    Toggle(
                        AppCopy.current.text("可见", "Visible"),
                        isOn: definition.isVisible
                    )
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .listRowSeparator(.hidden)
                    .help(
                        AppCopy.current.text(
                            "控制字段是否在 SELECT * 中默认可见，不会隐藏或删除数据。",
                            "Controls whether the column appears in SELECT * by default; it does not hide or delete data."
                        )
                    )
                }
                if context.descriptor.includesColumn(.defaultValue) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("默认值", "Default")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: defaultPresetBinding(definition),
                                options: WorkspaceDatabaseSchemaChoiceCatalog
                                    .defaultPresets(
                                        allowsNull: !context.isPrimaryKey
                                    ),
                                placeholder: AppCopy.current.text(
                                    "选择默认值模式",
                                    "Select Default Mode"
                                ),
                                accessibilityTitle: AppCopy.current.text(
                                    "默认值模式",
                                    "Default Value Mode"
                                )
                            )
                        }
                    }
                    .disabled(item.definition.isGenerated)
                    .help(generatedConflictHelp)
                    if item.definition.defaultPreset == .custom {
                        WorkspaceDatabaseSchemaInspectorFieldRow(
                            title: AppCopy.current.text("默认内容", "Default Value")
                        ) {
                            WorkspaceDatabaseSchemaInspectorPickerField {
                                TextField("", text: definition.defaultValue)
                                    .textFieldStyle(.plain)
                                    .font(.system(.subheadline, design: .monospaced))
                            }
                        }
                        .disabled(item.definition.isGenerated)
                    }
                }
                if context.descriptor.supportsOnUpdateExpression {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("更新时", "On Update")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: definition.onUpdateExpression,
                                options: WorkspaceDatabaseSchemaChoiceCatalog
                                    .onUpdateExpressions,
                                placeholder: AppCopy.current.text("无", "None"),
                                accessibilityTitle: AppCopy.current.text(
                                    "更新时表达式",
                                    "On Update Expression"
                                ),
                                allowsCustomValue: true,
                                usesMonospacedFont: true
                            )
                        }
                    }
                    .disabled(item.definition.isGenerated)
                    .help(generatedConflictHelp)
                }
            }

            if context.descriptor.includesColumn(.generatedStorage)
                || context.descriptor.includesColumn(.generationExpression) {
                Section(AppCopy.current.text("生成列", "GENERATED COLUMN")) {
                WorkspaceDatabaseSchemaInspectorFieldRow(
                    title: AppCopy.current.text("生成类型", "Generated")
                ) {
                    WorkspaceDatabaseSchemaInspectorPickerField {
                        WorkspaceDatabaseSchemaOptionPicker(
                            selection: generatedStorageBinding(definition),
                            options: context.descriptor.generatedStorages.map {
                                .init(value: $0.rawValue, title: $0.rawValue)
                            },
                            placeholder: "none",
                            accessibilityTitle: AppCopy.current.text(
                                "生成类型",
                                "Generated Storage"
                            )
                        )
                    }
                }
                .disabled(
                    !item.isNew
                        && !context.descriptor.supportsAlteringGeneratedColumns
                )
                .help(generatedAlterationHelp)
                if item.definition.isGenerated
                    && context.descriptor.includesColumn(.generationExpression) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text(
                            "生成表达式",
                            "Expression"
                        )
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            TextField(
                                AppCopy.current.text(
                                    "例如 price * quantity",
                                    "For example: price * quantity"
                                ),
                                text: definition.generationExpression
                            )
                            .textFieldStyle(.plain)
                            .font(.system(.subheadline, design: .monospaced))
                        }
                    }
                    .disabled(
                        !item.isNew
                            && !context.descriptor
                                .supportsAlteringGeneratedColumns
                    )
                    .help(generatedAlterationHelp)
                    Text(
                        AppCopy.current.text(
                            "只填写表达式，不需要输入 AS (...)。",
                            "Enter only the expression; AS (...) is added automatically."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            }
            }

            if context.descriptor.includesColumn(.comment) {
                Section(AppCopy.current.text("说明", "DESCRIPTION")) {
                WorkspaceDatabaseSchemaInspectorFieldRow(
                    title: AppCopy.current.text("注释", "Comment")
                ) {
                    WorkspaceDatabaseSchemaInspectorPickerField {
                        TextField("", text: definition.comment, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                            .lineLimit(3...12)
                    }
                }
            }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(item.isDeleted || !item.isEditable)
    }

    private func indexForm(
        _ item: WorkspaceDatabaseSchemaEditorState.IndexItem
    ) -> some View {
        let definition = indexBinding(item)
        return List {
            Section(AppCopy.current.text("索引", "INDEX")) {
                if context.descriptor.includesIndex(.name) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("名称", "Name")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            TextField("", text: definition.name)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .disabled(item.definition.kind == .primary)
                        }
                    }
                }
                if context.descriptor.includesIndex(.kind) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("类型", "Kind")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: indexKindBinding(definition),
                                options: indexKindOptions,
                                placeholder: AppCopy.current.text(
                                    "选择类型",
                                    "Select Kind"
                                ),
                                accessibilityTitle: AppCopy.current.text(
                                    "索引类型",
                                    "Index Kind"
                                ),
                                usesSearch: false
                            )
                        }
                    }
                }
                if context.descriptor.includesIndex(.method) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("索引方法", "Index Method")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            WorkspaceDatabaseSchemaOptionPicker(
                                selection: definition.method,
                                options: context.descriptor.indexMethods.map {
                                    .init(value: $0, title: $0)
                                },
                                placeholder: AppCopy.current.text(
                                    "选择方法",
                                    "Select Method"
                                ),
                                accessibilityTitle: AppCopy.current.text(
                                    "索引方法",
                                    "Index Method"
                                ),
                                allowsCustomValue: true,
                                usesMonospacedFont: true,
                                usesSearch: false
                            )
                        }
                        .disabled(
                            item.definition.kind == .fulltext
                                || item.definition.kind == .spatial
                        )
                    }
                }
                if context.descriptor.includesIndex(.visible) {
                    Toggle(
                        AppCopy.current.text("可见", "Visible"),
                        isOn: definition.isVisible
                    )
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .listRowSeparator(.hidden)
                    .help(
                        AppCopy.current.text(
                            "visible 时 MySQL 优化器可以使用该索引；invisible 时索引仍会维护，但优化器默认忽略它。",
                            "When visible, MySQL's optimizer may use the index. An invisible index is still maintained but ignored by the optimizer by default."
                        )
                    )
                }
            }

            if context.descriptor.includesIndex(.columns) {
                Section(AppCopy.current.text("索引字段", "INDEX COLUMNS")) {
                    ForEach(item.definition.columns) { column in
                        indexColumnRow(column, item: item)
                    }
                    WorkspaceInlineIconButton(
                        systemImageName: "plus",
                        title: AppCopy.current.text("添加索引字段", "Add Index Column")
                    ) {
                        var value = item.definition
                        value.columns.append(
                            .init(name: context.availableColumnNames.first ?? "")
                        )
                        context.updateIndex(item.id, value)
                    }
                }
            }

            if context.descriptor.includesIndex(.comment) {
                Section(AppCopy.current.text("说明", "DESCRIPTION")) {
                    WorkspaceDatabaseSchemaInspectorFieldRow(
                        title: AppCopy.current.text("注释", "Comment")
                    ) {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            TextField("", text: definition.comment, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .lineLimit(3...12)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(item.isDeleted)
    }

    private func indexColumnRow(
        _ column: WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition,
        item: WorkspaceDatabaseSchemaEditorState.IndexItem
    ) -> some View {
        let columnBinding = Binding(
            get: {
                item.definition.columns.first(where: { $0.id == column.id })
                    ?? column
            },
            set: { updated in
                var definition = item.definition
                guard let index = definition.columns.firstIndex(where: {
                    $0.id == column.id
                }) else { return }
                definition.columns[index] = updated
                context.updateIndex(item.id, definition)
            }
        )
        let index = item.definition.columns.firstIndex(where: {
            $0.id == column.id
        }) ?? 0
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                WorkspaceDatabaseSchemaOptionPicker(
                    selection: columnBinding.name,
                    options: WorkspaceDatabaseSchemaChoiceCatalog.columnNames(
                        context.availableColumnNames
                    ),
                    placeholder: AppCopy.current.text("选择字段", "Select Column"),
                    accessibilityTitle: AppCopy.current.text(
                        "索引字段",
                        "Index Column"
                    )
                )
                .frame(maxWidth: .infinity)

                WorkspaceInlineIconButton(
                    systemImageName: "minus",
                    title: AppCopy.current.text(
                        "移除索引字段",
                        "Remove Index Column"
                    ),
                    isEnabled: item.definition.columns.count > 1
                ) {
                    var definition = item.definition
                    definition.columns.removeAll { $0.id == column.id }
                    context.updateIndex(item.id, definition)
                }
            }

            if context.descriptor.supportsIndexPrefixLength
                || context.descriptor.supportsIndexDirection {
                HStack(spacing: 6) {
                    if context.descriptor.supportsIndexPrefixLength {
                        WorkspaceDatabaseSchemaInspectorPickerField {
                            TextField(
                                AppCopy.current.text("前缀长度", "Prefix Length"),
                                text: columnBinding.prefixLength
                            )
                            .textFieldStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if context.descriptor.supportsIndexDirection {
                        WorkspaceDatabaseSchemaOptionPicker(
                            selection: Binding(
                                get: {
                                    columnBinding.wrappedValue.isDescending
                                        ? "desc"
                                        : "asc"
                                },
                                set: {
                                    columnBinding.wrappedValue.isDescending = $0 == "desc"
                                }
                            ),
                            options: [
                                .init(value: "asc", title: "asc"),
                                .init(value: "desc", title: "desc"),
                            ],
                            placeholder: "asc",
                            accessibilityTitle: AppCopy.current.text(
                                "排序方向",
                                "Direction"
                            ),
                            usesSearch: false
                        )
                        .frame(width: 64)
                    }

                    WorkspaceInlineIconButton(
                        systemImageName: "arrow.up",
                        title: AppCopy.current.text("上移", "Move Up"),
                        isEnabled: index > 0
                    ) {
                        moveIndexColumn(column.id, in: item, by: -1)
                    }

                    WorkspaceInlineIconButton(
                        systemImageName: "arrow.down",
                        title: AppCopy.current.text("下移", "Move Down"),
                        isEnabled: index < item.definition.columns.count - 1
                    ) {
                        moveIndexColumn(column.id, in: item, by: 1)
                    }
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    private func columnBinding(
        _ item: WorkspaceDatabaseSchemaEditorState.ColumnItem
    ) -> Binding<WorkspaceDatabaseSchemaEditorState.ColumnDefinition> {
        Binding(
            get: { item.definition },
            set: { context.updateColumn(item.id, $0) }
        )
    }

    private func indexBinding(
        _ item: WorkspaceDatabaseSchemaEditorState.IndexItem
    ) -> Binding<WorkspaceDatabaseSchemaEditorState.IndexDefinition> {
        Binding(
            get: { item.definition },
            set: { definition in
                var definition = definition
                if definition.kind == .primary { definition.name = "PRIMARY" }
                context.updateIndex(item.id, definition)
            }
        )
    }

    private func defaultPresetBinding(
        _ definition: Binding<WorkspaceDatabaseSchemaEditorState.ColumnDefinition>
    ) -> Binding<String> {
        Binding(
            get: { definition.wrappedValue.defaultPreset.rawValue },
            set: { value in
                guard
                    let preset = WorkspaceDatabaseSchemaEditorState.DefaultPreset(
                        rawValue: value
                    )
                else {
                    return
                }
                definition.wrappedValue.applyDefaultPreset(preset)
            }
        )
    }

    private func characterSetBinding(
        _ definition: Binding<WorkspaceDatabaseSchemaEditorState.ColumnDefinition>
    ) -> Binding<String> {
        Binding(
            get: { definition.wrappedValue.characterSet },
            set: { value in
                definition.wrappedValue.applyCharacterSet(
                    value,
                    choices: context.schemaChoices
                )
            }
        )
    }

    private func collationBinding(
        _ definition: Binding<WorkspaceDatabaseSchemaEditorState.ColumnDefinition>
    ) -> Binding<String> {
        Binding(
            get: { definition.wrappedValue.collation },
            set: { value in
                definition.wrappedValue.applyCollation(
                    value,
                    choices: context.schemaChoices
                )
            }
        )
    }

    private func indexKindBinding(
        _ definition: Binding<WorkspaceDatabaseSchemaEditorState.IndexDefinition>
    ) -> Binding<String> {
        Binding(
            get: { definition.wrappedValue.kind.rawValue },
            set: { value in
                guard
                    let kind = WorkspaceDatabaseSchemaEditorState.IndexKind(
                        rawValue: value
                    )
                else {
                    return
                }
                definition.wrappedValue.kind = kind
                if kind == .primary {
                    definition.wrappedValue.name = "PRIMARY"
                }
            }
        )
    }

    private var indexKindOptions: [WorkspaceDatabaseSchemaOptionPicker.Option] {
        context.descriptor.indexKinds.map { kind in
            WorkspaceDatabaseSchemaChoiceCatalog.indexKinds.first(where: {
                $0.value == kind.rawValue
            }) ?? .init(value: kind.rawValue, title: kind.rawValue)
        }
    }

    private func generatedStorageBinding(
        _ definition: Binding<WorkspaceDatabaseSchemaEditorState.ColumnDefinition>
    ) -> Binding<String> {
        Binding(
            get: { definition.wrappedValue.generatedStorage.rawValue },
            set: { value in
                guard let storage = WorkspaceDatabaseSchemaEditorState
                    .GeneratedStorage(rawValue: value)
                else { return }
                definition.wrappedValue.applyGeneratedStorage(storage)
            }
        )
    }

    private func moveIndexColumn(
        _ columnID: UUID,
        in item: WorkspaceDatabaseSchemaEditorState.IndexItem,
        by offset: Int
    ) {
        var definition = item.definition
        guard let source = definition.columns.firstIndex(where: {
            $0.id == columnID
        }) else { return }
        let destination = source + offset
        guard definition.columns.indices.contains(destination) else { return }
        definition.columns.swapAt(source, destination)
        context.updateIndex(item.id, definition)
    }

    private var generatedConflictHelp: String {
        AppCopy.current.text(
            "生成列不能设置默认值、自动递增或 ON UPDATE。",
            "Generated columns cannot use a default value, auto increment, or ON UPDATE."
        )
    }

    private var generatedAlterationHelp: String {
        guard !context.descriptor.supportsAlteringGeneratedColumns else {
            return ""
        }
        return AppCopy.current.text(
            "PostgreSQL 17 不支持直接修改已有生成列的生成类型或表达式。",
            "PostgreSQL 17 cannot directly change the storage or expression of an existing generated column."
        )
    }

    private var generatedNullabilityHelp: String {
        AppCopy.current.text(
            "生成列的可空性由 MySQL 根据表达式处理。",
            "MySQL determines generated-column nullability from its expression."
        )
    }

    private var primaryKeyNullabilityHelp: String {
        AppCopy.current.text(
            "主键字段必须为 NOT NULL。",
            "Primary key columns must be NOT NULL."
        )
    }

    private var characterOptionsHelp: String {
        AppCopy.current.text(
            "字符集和排序规则仅适用于 CHAR、VARCHAR、TEXT、ENUM 和 SET 等字符类型。",
            "Character sets and collations apply only to character types such as CHAR, VARCHAR, TEXT, ENUM, and SET."
        )
    }

    private func matches(_ label: String) -> Bool {
        searchText.isEmpty || label.localizedStandardContains(searchText)
    }
}
