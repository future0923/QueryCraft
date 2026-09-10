struct WorkspaceDatabaseDataCellEditTarget: Equatable, Sendable {
    let rowIndex: Int
    let dataColumnIndex: Int
    let columns: [WorkspaceDatabaseDataColumn]
    let row: WorkspaceDatabaseDataRow

    var column: WorkspaceDatabaseDataColumn? {
        guard columns.indices.contains(dataColumnIndex) else { return nil }
        return columns[dataColumnIndex]
    }

    var originalValue: WorkspaceDatabaseDataCell {
        row.value(at: dataColumnIndex)
    }
}
