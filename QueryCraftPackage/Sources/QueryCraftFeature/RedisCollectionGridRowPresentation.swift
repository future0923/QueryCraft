import Foundation

struct RedisCollectionGridRowPresentation: Equatable {
    let id: UUID
    let values: [String]
    let modifiedDataIndexes: Set<Int>
    let changeState: RedisKeyEditableRow.ChangeState
    private let editableDataIndexes: Set<Int>

    init(row: RedisKeyEditableRow, kind: RedisCollectionGridKind) {
        id = row.id
        values = kind.cells.map { cell in
            switch cell {
            case .firstValue: row.firstValue
            case .secondValue: row.secondValue
            case .thirdValue: row.thirdValue
            }
        }
        var modifiedDataIndexes: Set<Int> = []
        for (index, cell) in kind.cells.enumerated() {
            let isModified = switch cell {
            case .firstValue: row.isFirstValueModified
            case .secondValue: row.isSecondValueModified
            case .thirdValue: row.isThirdValueModified
            }
            if isModified {
                modifiedDataIndexes.insert(index)
            }
        }
        self.modifiedDataIndexes = modifiedDataIndexes
        changeState = row.changeState
        rowIsBinaryReadOnly = row.isBinaryReadOnly
        editableDataIndexes = kind == .list ? [1] : Set(values.indices)
    }

    func isEditable(dataIndex: Int, isEnabled: Bool) -> Bool {
        isEnabled
            && changeState != .deleted
            && !rowIsBinaryReadOnly
            && values.indices.contains(dataIndex)
            && editableDataIndexes.contains(dataIndex)
    }

    private let rowIsBinaryReadOnly: Bool
}
