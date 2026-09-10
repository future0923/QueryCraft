import AppKit
import SwiftUI

enum WorkspaceDatabaseSchemaGridItemKind: Equatable {
    case column
    case index

    var addTitle: String {
        switch self {
        case .column:
            AppCopy.current.text("新增字段", "Add Column")
        case .index:
            AppCopy.current.text("新增索引", "Add Index")
        }
    }

    var duplicateTitle: String {
        switch self {
        case .column:
            AppCopy.current.text("复制字段", "Duplicate Column")
        case .index:
            AppCopy.current.text("复制索引", "Duplicate Index")
        }
    }

    var deleteTitle: String {
        switch self {
        case .column:
            AppCopy.current.text("删除字段", "Delete Column")
        case .index:
            AppCopy.current.text("删除索引", "Delete Index")
        }
    }
}

enum WorkspaceDatabaseSchemaGridContent: Equatable {
    case columns([WorkspaceDatabaseSchemaEditorState.ColumnItem])
    case indexes([WorkspaceDatabaseSchemaEditorState.IndexItem])

    var kind: WorkspaceDatabaseSchemaGridItemKind {
        switch self {
        case .columns: .column
        case .indexes: .index
        }
    }

    var count: Int {
        switch self {
        case let .columns(items): items.count
        case let .indexes(items): items.count
        }
    }

    var rowIDs: [UUID] {
        switch self {
        case let .columns(items): items.map(\.id)
        case let .indexes(items): items.map(\.id)
        }
    }
}

struct WorkspaceDatabaseSchemaGrid: NSViewRepresentable {
    let content: WorkspaceDatabaseSchemaGridContent
    let descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    let schemaChoices: WorkspaceDatabaseSchemaChoices
    let availableColumnNames: [String]
    @Binding var selection: UUID?
    let isEditable: Bool
    let usesAlternatingRows: Bool
    let accessibilityIdentifier: String
    let add: @MainActor () -> Void
    let duplicate: @MainActor (UUID) -> Void
    let updateColumn: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    let updateIndex: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> Void
    let primaryKeyColumnIDs: Set<UUID>
    let setPrimaryKey: @MainActor (UUID, Bool) -> Void
    let delete: @MainActor (UUID) -> Void

    func makeCoordinator() -> WorkspaceDatabaseSchemaGridCoordinator {
        WorkspaceDatabaseSchemaGridCoordinator(
            content: content,
            descriptor: descriptor,
            schemaChoices: schemaChoices,
            availableColumnNames: availableColumnNames,
            selection: $selection,
            isEditable: isEditable,
            usesAlternatingRows: usesAlternatingRows,
            accessibilityIdentifier: accessibilityIdentifier,
            add: add,
            duplicate: duplicate,
            updateColumn: updateColumn,
            updateIndex: updateIndex,
            primaryKeyColumnIDs: primaryKeyColumnIDs,
            setPrimaryKey: setPrimaryKey,
            delete: delete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.update(
            content: content,
            descriptor: descriptor,
            schemaChoices: schemaChoices,
            availableColumnNames: availableColumnNames,
            selection: $selection,
            isEditable: isEditable,
            usesAlternatingRows: usesAlternatingRows,
            accessibilityIdentifier: accessibilityIdentifier,
            add: add,
            duplicate: duplicate,
            updateColumn: updateColumn,
            updateIndex: updateIndex,
            primaryKeyColumnIDs: primaryKeyColumnIDs,
            setPrimaryKey: setPrimaryKey,
            delete: delete
        )
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: WorkspaceDatabaseSchemaGridCoordinator
    ) {
        coordinator.stopKeyCommandMonitoring()
    }
}
