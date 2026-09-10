import AppKit

struct WorkspaceDatabaseSchemaGridField: Equatable {
    private static let defaultMinimumWidth: CGFloat = 60

    enum Editing: Equatable {
        case text
        case options(allowsCustomValue: Bool)
        case boolean
        case defaultValue
        case indexColumns
    }

    let identifier: NSUserInterfaceItemIdentifier
    let title: String
    let editing: Editing
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    let columnField: WorkspaceDatabaseSchemaEditingDescriptor.ColumnField?
    let indexField: WorkspaceDatabaseSchemaEditingDescriptor.IndexField?

    static func fields(
        for kind: WorkspaceDatabaseSchemaGridItemKind,
        descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    ) -> [Self] {
        switch kind {
        case .column:
            descriptor.columnFields.compactMap {
                columnField($0, descriptor: descriptor)
            }
        case .index:
            descriptor.indexFields.map(indexField)
        }
    }

    private static func columnField(
        _ value: WorkspaceDatabaseSchemaEditingDescriptor.ColumnField,
        descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    ) -> Self? {
        return switch value {
        case .name:
            field(value, "name", AppCopy.current.text("名称", "Name"), .text)
        case .type:
            field(
                value,
                "type",
                AppCopy.current.text("类型", "Type"),
                .options(allowsCustomValue: true)
            )
        case .characterSet:
            field(
                value,
                "characterSet",
                AppCopy.current.text("字符集", "Character Set"),
                .options(allowsCustomValue: true)
            )
        case .collation:
            field(
                value,
                "collation",
                AppCopy.current.text("排序规则", "Collation"),
                .options(allowsCustomValue: true)
            )
        case .primaryKey:
            field(
                value,
                "primaryKey",
                AppCopy.current.text("主键", "Primary"),
                .boolean,
                maximumWidth: 100
            )
        case .nullable:
            field(
                value,
                "nullable",
                AppCopy.current.text("可为空", "Null"),
                .boolean,
                maximumWidth: 100
            )
        case .defaultValue:
            field(
                value,
                "default",
                AppCopy.current.text("默认值", "Default"),
                .defaultValue
            )
        case .automaticValue:
            switch descriptor.automaticValueStyle {
            case .autoIncrement?:
                field(
                    value,
                    "extra",
                    "Extra",
                    .options(allowsCustomValue: true),
                    maximumWidth: 360
                )
            case .identity?:
                field(
                    value,
                    "identity",
                    AppCopy.current.text("标识列", "Identity"),
                    .boolean,
                    maximumWidth: 100
                )
            case nil:
                nil
            }
        case .generatedStorage:
            field(
                value,
                "generated",
                AppCopy.current.text("生成类型", "Generated"),
                .options(allowsCustomValue: false),
                maximumWidth: 140
            )
        case .generationExpression:
            field(
                value,
                "generationExpression",
                AppCopy.current.text("生成表达式", "Expression"),
                .text,
                maximumWidth: 480
            )
        case .comment:
            field(
                value,
                "comment",
                AppCopy.current.text("注释", "Comment"),
                .text,
                maximumWidth: 480
            )
        }
    }

    private static func indexField(
        _ value: WorkspaceDatabaseSchemaEditingDescriptor.IndexField
    ) -> Self {
        switch value {
        case .name:
            field(value, "name", AppCopy.current.text("名称", "Name"), .text)
        case .kind:
            field(
                value,
                "kind",
                AppCopy.current.text("类型", "Kind"),
                .options(allowsCustomValue: false),
                maximumWidth: 180
            )
        case .columns:
            field(
                value,
                "columns",
                AppCopy.current.text("字段", "Columns"),
                .indexColumns,
                maximumWidth: 480
            )
        case .method:
            field(
                value,
                "method",
                AppCopy.current.text("方法", "Method"),
                .options(allowsCustomValue: true),
                maximumWidth: 180
            )
        case .visible:
            field(
                value,
                "visible",
                AppCopy.current.text("可见", "Visible"),
                .boolean,
                maximumWidth: 100
            )
        case .comment:
            field(
                value,
                "comment",
                AppCopy.current.text("注释", "Comment"),
                .text,
                maximumWidth: 480
            )
        }
    }

    private static func field(
        _ columnField: WorkspaceDatabaseSchemaEditingDescriptor.ColumnField,
        _ identifier: String,
        _ title: String,
        _ editing: Editing,
        minimumWidth: CGFloat = defaultMinimumWidth,
        maximumWidth: CGFloat = 360
    ) -> Self {
        Self(
            identifier: NSUserInterfaceItemIdentifier(
                "databaseSchema.\(identifier)"
            ),
            title: title,
            editing: editing,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth,
            columnField: columnField,
            indexField: nil
        )
    }

    private static func field(
        _ indexField: WorkspaceDatabaseSchemaEditingDescriptor.IndexField,
        _ identifier: String,
        _ title: String,
        _ editing: Editing,
        minimumWidth: CGFloat = defaultMinimumWidth,
        maximumWidth: CGFloat = 360
    ) -> Self {
        Self(
            identifier: NSUserInterfaceItemIdentifier(
                "databaseSchema.\(identifier)"
            ),
            title: title,
            editing: editing,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth,
            columnField: nil,
            indexField: indexField
        )
    }
}
