import SwiftUI

struct WorkspaceNewTableOptionsView: View {
    let tableName: Binding<String>?
    @Binding var options: WorkspaceDatabaseTableOptions
    let schemaChoices: WorkspaceDatabaseSchemaChoices
    let isDisabled: Bool
    let allowsDatabaseDefaults: Bool

    init(
        tableName: Binding<String>? = nil,
        options: Binding<WorkspaceDatabaseTableOptions>,
        schemaChoices: WorkspaceDatabaseSchemaChoices,
        isDisabled: Bool,
        allowsDatabaseDefaults: Bool = true
    ) {
        self.tableName = tableName
        _options = options
        self.schemaChoices = schemaChoices
        self.isDisabled = isDisabled
        self.allowsDatabaseDefaults = allowsDatabaseDefaults
    }

    var body: some View {
        ScrollView {
            Form {
                Section(AppCopy.current.text("常用选项", "GENERAL")) {
                    if let tableName {
                        textField(
                            AppCopy.current.text("表名", "Table Name"),
                            text: tableName,
                            help: AppCopy.current.text(
                                "输入要创建的表名。",
                                "Enter the name of the table to create."
                            ),
                            accessibilityIdentifier: "newTableNameField"
                        )
                    }
                    optionPicker(
                        AppCopy.current.text("表引擎", "Table Engine"),
                        selection: $options.engine,
                        values: defaultOptionValues + (
                            schemaChoices.engines.isEmpty
                                ? ["InnoDB", "MyISAM", "MEMORY", "CSV", "ARCHIVE"]
                                : schemaChoices.engines
                        ),
                        help: AppCopy.current.text(
                            "留空时使用 MySQL 的默认存储引擎。",
                            "Leave empty to use MySQL's default storage engine."
                        ),
                        usesPlainMenuStyle: true
                    )
                    optionPicker(
                        AppCopy.current.text("默认字符集", "Default Character Set"),
                        selection: characterSetBinding,
                        options: withoutDatabaseDefault(
                            WorkspaceDatabaseSchemaChoiceCatalog
                                .characterSets(schemaChoices)
                        ),
                        help: AppCopy.current.text(
                            "未单独指定字符集的文本字段将继承此设置。",
                            "Text columns without their own character set inherit this value."
                        ),
                        usesSearch: true
                    )
                    optionPicker(
                        AppCopy.current.text("默认排序规则", "Default Collation"),
                        selection: collationBinding,
                        options: withoutDatabaseDefault(
                            WorkspaceDatabaseSchemaChoiceCatalog.collations(
                                schemaChoices,
                                characterSet: options.characterSet
                            )
                        ),
                        help: AppCopy.current.text(
                            "选择排序规则时会同步对应的字符集。",
                            "Selecting a collation also selects its character set."
                        ),
                        usesSearch: true
                    )
                    optionPicker(
                        AppCopy.current.text("行格式", "Row Format"),
                        selection: $options.rowFormat,
                        values: defaultOptionValues + [
                            "DYNAMIC", "COMPACT", "COMPRESSED", "REDUNDANT", "FIXED",
                        ],
                        help: AppCopy.current.text(
                            "是否支持某种行格式取决于存储引擎和 MySQL 版本。",
                            "Row format support depends on the storage engine and MySQL version."
                        ),
                        usesPlainMenuStyle: true
                    )
                    textField(
                        allowsDatabaseDefaults
                            ? AppCopy.current.text(
                                "自增初始值",
                                "Initial Auto-Increment"
                            )
                            : AppCopy.current.text(
                                "下一个自增值",
                                "Next Auto-Increment"
                            ),
                        text: $options.autoIncrement,
                        help: AppCopy.current.text(
                            "设置下一条自增记录使用的值；留空时由 MySQL 根据现有数据决定。",
                            "Sets the value for the next auto-increment row; leave empty to let MySQL derive it from existing data."
                        )
                    )
                    textField(
                        AppCopy.current.text("表备注", "Table Comment"),
                        text: $options.comment,
                        help: AppCopy.current.text(
                            "为表添加备注；留空时不设置备注。",
                            "Adds a table comment; leave empty to omit it."
                        )
                    )
                }

                Section(AppCopy.current.text("高级选项", "ADVANCED")) {
                    textField(
                        AppCopy.current.text("平均行长度", "Average Row Length"),
                        text: $options.averageRowLength,
                        help: AppCopy.current.text(
                            "向存储引擎提供预计的平均行大小，不是行大小限制。",
                            "Provides the storage engine with an estimated average row size; it is not a row-size limit."
                        )
                    )
                    textField(
                        AppCopy.current.text("最小行数", "Minimum Rows"),
                        text: $options.minimumRows,
                        help: AppCopy.current.text(
                            "向存储引擎提供预计的最小行数，不会限制表的实际行数。",
                            "Provides an estimated minimum row count; it does not constrain the table's actual row count."
                        )
                    )
                    textField(
                        AppCopy.current.text("最大行数", "Maximum Rows"),
                        text: $options.maximumRows,
                        help: AppCopy.current.text(
                            "向存储引擎提供预计的最大行数，通常不是严格上限。",
                            "Provides an estimated maximum row count; it is generally not a strict limit."
                        )
                    )
                    textField(
                        AppCopy.current.text("键块大小", "Key Block Size"),
                        text: $options.keyBlockSize,
                        help: AppCopy.current.text(
                            "设置支持该选项的存储引擎所使用的索引块或压缩页大小。",
                            "Sets the index block or compressed page size for storage engines that support it."
                        )
                    )
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 620)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .disabled(isDisabled)
    }

    private var characterSetBinding: Binding<String> {
        Binding(
            get: { options.characterSet },
            set: { value in
                options.applyCharacterSet(value, choices: schemaChoices)
            }
        )
    }

    private var defaultOptionValues: [String] {
        allowsDatabaseDefaults ? [""] : []
    }

    private func withoutDatabaseDefault(
        _ options: [WorkspaceDatabaseSchemaOptionPicker.Option]
    ) -> [WorkspaceDatabaseSchemaOptionPicker.Option] {
        allowsDatabaseDefaults
            ? options
            : options.filter { !$0.value.isEmpty }
    }

    private var collationBinding: Binding<String> {
        Binding(
            get: { options.collation },
            set: { value in
                options.applyCollation(value, choices: schemaChoices)
            }
        )
    }

    private func optionPicker(
        _ title: String,
        selection: Binding<String>,
        values: [String],
        help: String,
        usesSearch: Bool = false,
        usesPlainMenuStyle: Bool = false
    ) -> some View {
        optionPicker(
            title,
            selection: selection,
            options: values.map {
                WorkspaceDatabaseSchemaOptionPicker.Option(
                    value: $0,
                    title: $0.isEmpty
                        ? AppCopy.current.text(
                            "使用数据库默认值",
                            "Use Database Default"
                        )
                        : $0
                )
            },
            help: help,
            usesSearch: usesSearch,
            usesPlainMenuStyle: usesPlainMenuStyle
        )
    }

    private func optionPicker(
        _ title: String,
        selection: Binding<String>,
        options: [WorkspaceDatabaseSchemaOptionPicker.Option],
        help: String,
        usesSearch: Bool = false,
        usesPlainMenuStyle: Bool = false
    ) -> some View {
        LabeledContent(title) {
            WorkspaceDatabaseSchemaInspectorPickerField {
                WorkspaceDatabaseSchemaOptionPicker(
                    selection: selection,
                    options: localizedDefault(options),
                    placeholder: AppCopy.current.text(
                        "使用数据库默认值",
                        "Use Database Default"
                    ),
                    accessibilityTitle: title,
                    usesSearch: usesSearch,
                    usesPlainMenuStyle: usesPlainMenuStyle,
                    alignsSelectionTrailing: true
                )
            }
            .frame(minWidth: 180, idealWidth: 280, maxWidth: 320)
        }
        .help(help)
    }

    private func textField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal,
        lineLimit: ClosedRange<Int>? = nil,
        help: String,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        LabeledContent(title) {
            WorkspaceDatabaseSchemaInspectorPickerField {
                TextField("", text: text, axis: axis)
                    .lineLimit(lineLimit ?? 1...1)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(accessibilityIdentifier ?? title)
            }
            .frame(minWidth: 180, idealWidth: 280, maxWidth: 320)
        }
        .help(help)
    }

    private func localizedDefault(
        _ options: [WorkspaceDatabaseSchemaOptionPicker.Option]
    ) -> [WorkspaceDatabaseSchemaOptionPicker.Option] {
        options.map { option in
            guard option.value.isEmpty else { return option }
            return WorkspaceDatabaseSchemaOptionPicker.Option(
                value: "",
                title: AppCopy.current.text(
                    "使用数据库默认值",
                    "Use Database Default"
                )
            )
        }
    }
}
