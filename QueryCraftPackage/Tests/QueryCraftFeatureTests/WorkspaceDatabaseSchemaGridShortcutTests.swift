import AppKit
import SwiftUI
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspaceDatabaseSchemaGridShortcutTests {
    @Test
    func commandLettersUsePhysicalKeysForPublishedSchemaActions() async throws {
        let selectedID = UUID()
        var addCount = 0
        var duplicatedIDs: [UUID] = []
        let actions = WorkspaceDatabaseSchemaRowCommandActions(
            kind: .column,
            selectedID: selectedID,
            canAdd: true,
            canDuplicate: true,
            canDelete: true,
            add: { addCount += 1 },
            duplicate: { duplicatedIDs.append($0) },
            delete: { _ in }
        )
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: nil,
            filterPresentationActions: nil,
            objectDetailTabActions: nil,
            isSuspended: false,
            schemaActions: actions
        )
        let addEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 34
            )
        )
        let duplicateEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "文",
                charactersIgnoringModifiers: "文",
                isARepeat: false,
                keyCode: 2
            )
        )

        #expect(coordinator.handle(addEvent))
        #expect(coordinator.handle(duplicateEvent))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
        #expect(addCount == 1)
        #expect(duplicatedIDs == [selectedID])
    }

    @Test
    func commandIAddsColumnWhileSchemaGridIsFirstResponder() throws {
        var addCount = 0
        var selection: UUID?
        let coordinator = WorkspaceDatabaseSchemaGridCoordinator(
            content: .columns([]),
            descriptor: .schemaGridTest,
            schemaChoices: .empty,
            availableColumnNames: [],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            isEditable: true,
            usesAlternatingRows: true,
            accessibilityIdentifier: "testSchemaGrid",
            add: { addCount += 1 },
            duplicate: { _ in },
            updateColumn: { _, _ in },
            updateIndex: { _, _ in },
            primaryKeyColumnIDs: [],
            setPrimaryKey: { _, _ in },
            delete: { _ in }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 34
            )
        )

        #expect(
            coordinator.handleKeyCommand(
                event,
                firstResponder: tableView
            )
        )
        #expect(addCount == 1)
        coordinator.stopKeyCommandMonitoring()
    }

    @Test
    func primaryKeyChangeRefreshesOnlyTheAffectedVisibleRow() throws {
        let items = ["id", "name"].map { name in
            WorkspaceDatabaseSchemaEditorState.ColumnItem(
                column: WorkspaceDatabaseColumn(
                    name: name,
                    type: "int",
                    collation: nil,
                    isNullable: false,
                    key: "",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                )
            )
        }
        var selection: UUID?
        let coordinator = WorkspaceDatabaseSchemaGridCoordinator(
            content: .columns(items),
            descriptor: .schemaGridTest,
            schemaChoices: .empty,
            availableColumnNames: [],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            isEditable: true,
            usesAlternatingRows: true,
            accessibilityIdentifier: "testSchemaGrid",
            add: {},
            duplicate: { _ in },
            updateColumn: { _, _ in },
            updateIndex: { _, _ in },
            primaryKeyColumnIDs: [],
            setPrimaryKey: { _, _ in },
            delete: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 960, height: 240)
        scrollView.layoutSubtreeIfNeeded()
        let firstRow = try #require(
            tableView.rowView(atRow: 0, makeIfNecessary: true)
                as? WorkspaceDatabaseSchemaRowView
        )
        let secondRow = try #require(
            tableView.rowView(atRow: 1, makeIfNecessary: true)
                as? WorkspaceDatabaseSchemaRowView
        )
        #expect(firstRow.booleanValue(at: 4) == false)
        #expect(secondRow.booleanValue(at: 4) == false)

        coordinator.update(
            content: .columns(items),
            descriptor: .schemaGridTest,
            schemaChoices: .empty,
            availableColumnNames: [],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            isEditable: true,
            usesAlternatingRows: true,
            accessibilityIdentifier: "testSchemaGrid",
            add: {},
            duplicate: { _ in },
            updateColumn: { _, _ in },
            updateIndex: { _, _ in },
            primaryKeyColumnIDs: [items[0].id],
            setPrimaryKey: { _, _ in },
            delete: { _ in }
        )

        #expect(
            tableView.rowView(atRow: 0, makeIfNecessary: false) === firstRow
        )
        #expect(
            tableView.rowView(atRow: 1, makeIfNecessary: false) === secondRow
        )
        #expect(firstRow.booleanValue(at: 4) == true)
        #expect(secondRow.booleanValue(at: 4) == false)
        coordinator.stopKeyCommandMonitoring()
    }

    @Test
    func restoringEditabilityReconfiguresVisibleIndexRowsInPlace() throws {
        let item = WorkspaceDatabaseSchemaEditorState.IndexItem(
            index: WorkspaceDatabaseIndex(
                name: "users_name_idx",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "name",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    ),
                ],
                isUnique: false,
                type: "BTREE",
                cardinality: nil,
                isVisible: true,
                comment: ""
            )
        )
        var selection: UUID?
        let coordinator = WorkspaceDatabaseSchemaGridCoordinator(
            content: .indexes([item]),
            descriptor: .schemaGridTest,
            schemaChoices: .empty,
            availableColumnNames: ["name"],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            isEditable: false,
            usesAlternatingRows: true,
            accessibilityIdentifier: "testSchemaGrid",
            add: {},
            duplicate: { _ in },
            updateColumn: { _, _ in },
            updateIndex: { _, _ in },
            primaryKeyColumnIDs: [],
            setPrimaryKey: { _, _ in },
            delete: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 960, height: 240)
        scrollView.layoutSubtreeIfNeeded()
        let rowView = try #require(
            tableView.rowView(atRow: 0, makeIfNecessary: true)
                as? WorkspaceDatabaseSchemaRowView
        )
        #expect(!rowView.isEditable(at: 3))

        coordinator.update(
            content: .indexes([item]),
            descriptor: .schemaGridTest,
            schemaChoices: .empty,
            availableColumnNames: ["name"],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            isEditable: true,
            usesAlternatingRows: true,
            accessibilityIdentifier: "testSchemaGrid",
            add: {},
            duplicate: { _ in },
            updateColumn: { _, _ in },
            updateIndex: { _, _ in },
            primaryKeyColumnIDs: [],
            setPrimaryKey: { _, _ in },
            delete: { _ in }
        )

        #expect(
            tableView.rowView(atRow: 0, makeIfNecessary: false) === rowView
        )
        #expect(rowView.isEditable(at: 3))
        coordinator.stopKeyCommandMonitoring()
    }
}

private extension WorkspaceDatabaseSchemaEditingDescriptor {
    static let schemaGridTest = Self(
        columnFields: ColumnField.allCases,
        indexFields: IndexField.allCases,
        defaultColumnType: "VARCHAR(255)",
        columnTypes: ["INT", "VARCHAR(255)"],
        indexKinds: WorkspaceDatabaseSchemaEditorState.IndexKind.allCases,
        indexMethods: ["BTREE", "HASH"],
        generatedStorages: WorkspaceDatabaseSchemaEditorState.GeneratedStorage
            .allCases,
        automaticValueStyle: .autoIncrement,
        supportsTableOptions: true,
        supportsColumnVisibility: true,
        supportsOnUpdateExpression: true,
        supportsAlteringGeneratedColumns: true,
        supportsIndexPrefixLength: true,
        supportsIndexDirection: true
    )
}
