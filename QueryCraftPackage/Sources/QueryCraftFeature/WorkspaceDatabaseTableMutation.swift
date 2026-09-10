import Foundation

public enum WorkspaceDatabaseTableMutation: Equatable, Sendable {
    case create(
        databaseName: String,
        tableName: String,
        columns: [WorkspaceDatabaseSchemaEditorState.ColumnItem],
        indexes: [WorkspaceDatabaseSchemaEditorState.IndexItem],
        options: WorkspaceDatabaseTableOptions = .init()
    )
    case rename(
        selection: WorkspaceDatabaseObjectSelection,
        newName: String
    )
    case drop(selection: WorkspaceDatabaseObjectSelection)

    public var databaseName: String {
        switch self {
        case let .create(databaseName, _, _, _, _):
            databaseName
        case let .rename(selection, _), let .drop(selection):
            selection.databaseName
        }
    }

    public var sourceSelection: WorkspaceDatabaseObjectSelection? {
        switch self {
        case .create:
            nil
        case let .rename(selection, _), let .drop(selection):
            selection
        }
    }

    public var resultingSelection: WorkspaceDatabaseObjectSelection? {
        switch self {
        case let .create(databaseName, tableName, _, _, _):
            WorkspaceDatabaseObjectSelection(
                databaseName: databaseName,
                objectName: tableName,
                kind: .table
            )
        case let .rename(selection, newName):
            WorkspaceDatabaseObjectSelection(
                databaseName: selection.databaseName,
                objectName: newName,
                kind: .table
            )
        case .drop:
            nil
        }
    }

    public var statementKind: SQLStatementKind {
        switch self {
        case .create:
            .ddl(.create)
        case .rename:
            .ddl(.alter)
        case .drop:
            .ddl(.drop)
        }
    }
}

enum WorkspaceDatabaseTableMutationError: LocalizedError, Equatable {
    case safetyLockEnabled
    case contextChanged

    var errorDescription: String? {
        switch self {
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已启用，已阻止表结构更改。",
                "Safety Lock is enabled, so the table change was blocked."
            )
        case .contextChanged:
            AppCopy.current.text(
                "表编辑上下文已更改，请重试。",
                "The table editing context changed. Try again."
            )
        }
    }
}
