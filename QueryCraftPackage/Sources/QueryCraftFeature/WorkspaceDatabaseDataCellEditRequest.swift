import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

struct WorkspaceDatabaseDataCellEditRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let selection: WorkspaceDatabaseObjectSelection
    let column: WorkspaceDatabaseColumn
    let originalValue: WorkspaceDatabaseDataCell
    let initialValue: WorkspaceDatabaseDataCell
    let primaryKey: [WorkspaceDatabaseDataCellUpdateCondition]

    #if !os(iOS)
    static func make(
        selection: WorkspaceDatabaseObjectSelection,
        target: WorkspaceDatabaseDataCellEditTarget,
        details: WorkspaceDatabaseObjectDetails
    ) throws -> Self {
        try make(selection: selection, target: target, columns: details.columns)
    }
    #endif

    static func make(selection: WorkspaceDatabaseObjectSelection,
                     target: WorkspaceDatabaseDataCellEditTarget,
                     columns: [WorkspaceDatabaseColumn]) throws -> Self {
        guard selection.kind == .table else {
            throw WorkspaceDatabaseDataCellEditError.tableRequired
        }
        guard
            let dataColumn = target.column,
            let column = columns.first(where: {
                $0.name == (dataColumn.origin?.columnName ?? dataColumn.name)
            })
        else {
            throw WorkspaceDatabaseDataCellEditError.metadataUnavailable
        }
        guard !column.isGenerated else {
            throw WorkspaceDatabaseDataCellEditError.generatedColumn
        }
        if case .binary = target.originalValue {
            throw WorkspaceDatabaseDataCellEditError.binaryValueUnavailable
        }

        let keyColumns = columns.filter {
            $0.key.uppercased() == "PRI"
        }
        guard !keyColumns.isEmpty else {
            throw WorkspaceDatabaseDataCellEditError.primaryKeyRequired
        }
        let primaryKey = try keyColumns.map { keyColumn in
            guard
                let dataColumnIndex = target.columns.firstIndex(where: {
                    ($0.origin?.columnName ?? $0.name) == keyColumn.name
                })
            else {
                throw WorkspaceDatabaseDataCellEditError
                    .primaryKeyValueUnavailable(keyColumn.name)
            }
            let value = target.row.value(at: dataColumnIndex)
            if case .binary = value {
                throw WorkspaceDatabaseDataCellEditError
                    .primaryKeyValueUnavailable(keyColumn.name)
            }
            return WorkspaceDatabaseDataCellUpdateCondition(
                columnName: keyColumn.name,
                value: value
            )
        }

        return Self(
            selection: selection,
            column: column,
            originalValue: target.originalValue,
            initialValue: target.originalValue,
            primaryKey: primaryKey
        )
    }

    func withInitialValue(_ value: WorkspaceDatabaseDataCell) -> Self {
        Self(
            selection: selection,
            column: column,
            originalValue: originalValue,
            initialValue: value,
            primaryKey: primaryKey
        )
    }

    var initialText: String {
        guard case let .text(value) = initialValue else { return "" }
        return value
    }

    var initiallyUsesNull: Bool {
        initialValue == .null
    }

    func makeUpdate(
        text: String,
        usesNull: Bool
    ) throws -> WorkspaceDatabaseDataCellUpdate {
        if usesNull, !column.isNullable {
            throw WorkspaceDatabaseDataCellEditError.nullNotAllowed
        }
        let newValue = usesNull
            ? WorkspaceDatabaseDataCell.null
            : WorkspaceDatabaseDataCell.text(text)
        guard newValue != originalValue || initialValue != originalValue else {
            throw WorkspaceDatabaseDataCellEditError.unchangedValue
        }
        return WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: column.name,
            originalValue: originalValue,
            newValue: newValue,
            primaryKey: primaryKey
        )
    }

    func makeDefaultUpdate() throws -> WorkspaceDatabaseDataCellUpdate {
        guard column.defaultValue != nil
            || column.extra.localizedCaseInsensitiveContains(
                "default_generated"
            )
        else {
            throw WorkspaceDatabaseDataCellEditError.defaultUnavailable
        }
        return WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: column.name,
            originalValue: originalValue,
            newValue: originalValue,
            primaryKey: primaryKey,
            assignment: .useDefault
        )
    }
}
