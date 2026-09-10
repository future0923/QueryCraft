import Foundation

struct WorkspaceDatabaseDataRowInsertDraftRow: Equatable, Identifiable, Sendable {
    let id: UUID
    var drafts: [String: WorkspaceDatabaseDataRowInsertDraft]
    var editedColumnNames: Set<String>

    init(
        id: UUID = UUID(),
        drafts: [String: WorkspaceDatabaseDataRowInsertDraft],
        editedColumnNames: Set<String> = []
    ) {
        self.id = id
        self.drafts = drafts
        self.editedColumnNames = editedColumnNames
    }
}

struct WorkspaceDatabaseDataRowInsertEditorState: Equatable, Sendable {
    private(set) var request: WorkspaceDatabaseDataRowInsertRequest?
    private(set) var draftRows: [WorkspaceDatabaseDataRowInsertDraftRow] = []
    private(set) var isSubmitting = false
    private(set) var revision = 0

    var isPresented: Bool { !draftRows.isEmpty }
    var rowCount: Int { draftRows.count }
    var rowIDs: [UUID] { draftRows.map(\.id) }
    var hasEditedColumns: Bool {
        draftRows.contains { !$0.editedColumnNames.isEmpty }
    }

    mutating func present(_ request: WorkspaceDatabaseDataRowInsertRequest) {
        self.request = request
        draftRows = [makeBlankRow(request: request)]
        isSubmitting = false
        revision += 1
    }

    mutating func present(
        _ request: WorkspaceDatabaseDataRowInsertRequest,
        pastedRows: [WorkspaceDatabaseDataRowInsertDraftRow]
    ) throws {
        guard !pastedRows.isEmpty else {
            throw WorkspaceGridPasteError.malformed
        }
        self.request = request
        draftRows = pastedRows
        isSubmitting = false
        revision += 1
    }

    mutating func applyPastedRows(
        _ pastedRows: [WorkspaceDatabaseDataRowInsertDraftRow],
        replacingRowID rowID: UUID?
    ) throws {
        guard request != nil, !isSubmitting else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        guard !pastedRows.isEmpty else {
            throw WorkspaceGridPasteError.malformed
        }
        if let rowID,
           let rowIndex = draftRows.firstIndex(where: { $0.id == rowID })
        {
            var first = pastedRows[0]
            first = WorkspaceDatabaseDataRowInsertDraftRow(
                id: rowID,
                drafts: first.drafts,
                editedColumnNames: first.editedColumnNames
            )
            draftRows[rowIndex] = first
            draftRows.insert(
                contentsOf: pastedRows.dropFirst(),
                at: rowIndex + 1
            )
        } else {
            draftRows.append(contentsOf: pastedRows)
        }
        revision += 1
    }

    mutating func appendRow() {
        guard let request, !isSubmitting else { return }
        draftRows.append(makeBlankRow(request: request))
        revision += 1
    }

    mutating func present(
        _ request: WorkspaceDatabaseDataRowInsertRequest,
        duplicating row: WorkspaceDatabaseDataRow,
        pageColumns: [WorkspaceDatabaseDataColumn]
    ) throws {
        self.request = request
        draftRows = [
            try makeDuplicateRow(
                request: request,
                row: row,
                pageColumns: pageColumns
            ),
        ]
        isSubmitting = false
        revision += 1
    }

    mutating func appendRow(
        duplicating row: WorkspaceDatabaseDataRow,
        pageColumns: [WorkspaceDatabaseDataColumn]
    ) throws {
        guard let request, !isSubmitting else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        draftRows.append(
            try makeDuplicateRow(
                request: request,
                row: row,
                pageColumns: pageColumns
            )
        )
        revision += 1
    }

    mutating func duplicateRow(id: UUID) {
        guard
            !isSubmitting,
            let row = draftRows.first(where: { $0.id == id })
        else {
            return
        }
        draftRows.append(
            WorkspaceDatabaseDataRowInsertDraftRow(
                drafts: row.drafts,
                editedColumnNames: row.editedColumnNames
            )
        )
        revision += 1
    }

    mutating func removeRow(id: UUID) {
        guard !isSubmitting else { return }
        let previousCount = draftRows.count
        draftRows.removeAll { $0.id == id }
        guard draftRows.count != previousCount else { return }
        if draftRows.isEmpty {
            request = nil
            isSubmitting = false
        }
        revision += 1
    }

    mutating func retainDraftRows(_ rowIDs: Set<UUID>) {
        let retained = draftRows.filter { rowIDs.contains($0.id) }
        guard retained.count != draftRows.count else { return }
        draftRows = retained
        if retained.isEmpty { request = nil }
        revision += 1
    }

    mutating func update(
        rowID: UUID,
        columnName: String,
        draft: WorkspaceDatabaseDataRowInsertDraft
    ) {
        guard
            request?.columns.contains(where: { $0.id == columnName }) == true,
            let rowIndex = draftRows.firstIndex(where: { $0.id == rowID })
        else {
            return
        }
        draftRows[rowIndex].drafts[columnName] = draft
        draftRows[rowIndex].editedColumnNames.insert(columnName)
        revision += 1
    }

    mutating func update(
        columnName: String,
        draft: WorkspaceDatabaseDataRowInsertDraft
    ) {
        guard let rowID = draftRows.first?.id else { return }
        update(rowID: rowID, columnName: columnName, draft: draft)
    }

    mutating func replaceDraftRow(
        id rowID: UUID,
        drafts: [String: WorkspaceDatabaseDataRowInsertDraft],
        editedColumnNames: Set<String>
    ) {
        guard
            let request,
            let rowIndex = draftRows.firstIndex(where: { $0.id == rowID })
        else {
            return
        }
        let knownColumnNames = Set(request.columns.map(\.id))
        let normalizedDrafts = Dictionary(
            uniqueKeysWithValues: request.columns.map { column in
                (column.id, drafts[column.id] ?? column.initialDraft)
            }
        )
        let replacement = WorkspaceDatabaseDataRowInsertDraftRow(
            id: rowID,
            drafts: normalizedDrafts,
            editedColumnNames: editedColumnNames.intersection(knownColumnNames)
        )
        guard draftRows[rowIndex] != replacement else { return }
        draftRows[rowIndex] = replacement
        revision += 1
    }

    mutating func setSubmitting(_ isSubmitting: Bool) {
        guard self.isSubmitting != isSubmitting else { return }
        self.isSubmitting = isSubmitting
        revision += 1
    }

    mutating func dismiss() {
        request = nil
        draftRows.removeAll(keepingCapacity: false)
        isSubmitting = false
        revision += 1
    }

    func rowID(at index: Int) -> UUID? {
        draftRows.indices.contains(index) ? draftRows[index].id : nil
    }

    func rowIndex(id: UUID) -> Int? {
        draftRows.firstIndex { $0.id == id }
    }

    func hasEditedColumns(rowID: UUID) -> Bool {
        draftRows.first(where: { $0.id == rowID })?
            .editedColumnNames.isEmpty == false
    }

    func hasEditedColumn(rowID: UUID, columnName: String) -> Bool {
        draftRows.first(where: { $0.id == rowID })?
            .editedColumnNames.contains(columnName) == true
    }

    func draft(
        rowID: UUID,
        for columnName: String
    ) -> WorkspaceDatabaseDataRowInsertDraft? {
        guard
            let column = request?.columns.first(where: { $0.id == columnName }),
            let row = draftRows.first(where: { $0.id == rowID })
        else {
            return nil
        }
        return row.drafts[columnName] ?? column.initialDraft
    }

    func draft(for columnName: String) -> WorkspaceDatabaseDataRowInsertDraft? {
        guard let rowID = draftRows.first?.id else { return nil }
        return draft(rowID: rowID, for: columnName)
    }

    func column(
        named columnName: String
    ) -> WorkspaceDatabaseDataRowInsertColumn? {
        request?.columns.first(where: { $0.id == columnName })
    }

    func makeInsert(rowID: UUID) throws -> WorkspaceDatabaseDataRowInsert {
        guard
            let request,
            let row = draftRows.first(where: { $0.id == rowID })
        else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        return request.makeInsert(
            drafts: row.drafts,
            includedColumnNames: row.editedColumnNames
        )
    }

    func makeInserts() throws -> [WorkspaceDatabaseDataRowInsert] {
        guard let request else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        return draftRows.map { row in
            request.makeInsert(
                drafts: row.drafts,
                includedColumnNames: row.editedColumnNames
            )
        }
    }

    func makeInsert() throws -> WorkspaceDatabaseDataRowInsert {
        guard let rowID = draftRows.first?.id else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        return try makeInsert(rowID: rowID)
    }

    private func makeBlankRow(
        request: WorkspaceDatabaseDataRowInsertRequest
    ) -> WorkspaceDatabaseDataRowInsertDraftRow {
        WorkspaceDatabaseDataRowInsertDraftRow(
            drafts: Dictionary(
                uniqueKeysWithValues: request.columns.map {
                    ($0.id, $0.initialDraft)
                }
            )
        )
    }

    private func makeDuplicateRow(
        request: WorkspaceDatabaseDataRowInsertRequest,
        row: WorkspaceDatabaseDataRow,
        pageColumns: [WorkspaceDatabaseDataColumn]
    ) throws -> WorkspaceDatabaseDataRowInsertDraftRow {
        var duplicate = makeBlankRow(request: request)
        for column in request.columns where !column.isAutoIncrement {
            guard let pageColumn = pageColumns.first(where: {
                $0.name == column.id
            }) else {
                continue
            }
            let value = row.value(at: pageColumn.id)
            switch value {
            case .null:
                duplicate.drafts[column.id] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .null,
                    text: ""
                )
            case let .text(text):
                duplicate.drafts[column.id] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .value,
                    text: text
                )
            case .binary:
                throw WorkspaceDatabaseDataRowInsertError
                    .binaryValueUnavailable(column.id)
            }
            duplicate.editedColumnNames.insert(column.id)
        }
        return duplicate
    }
}
