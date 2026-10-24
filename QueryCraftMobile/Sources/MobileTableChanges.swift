import Foundation
import Observation
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport

extension MobileTableColumn {
    var editingColumn: WorkspaceDatabaseColumn {
        .init(name: name, type: type, collation: nil, isNullable: isNullable, key: key,
              defaultValue: defaultValue, extra: extra, comment: comment)
    }
}
extension MobileDatabaseObject {
    var editingSelection: WorkspaceDatabaseObjectSelection {
        .init(databaseName: database, objectName: schemaName.map {
            PostgreSQLDataMutation.TableIdentity(schema: $0, name: name).sql
        } ?? name, kind: kind == .table ? .table : .view)
    }
}

@MainActor @Observable final class MobileInsertDraft: Identifiable {
    let id: UUID
    let request: WorkspaceDatabaseDataRowInsertRequest
    var drafts: [String: WorkspaceDatabaseDataRowInsertDraft]
    var edited = Set<String>()
    init(request: WorkspaceDatabaseDataRowInsertRequest, id: UUID = UUID()) {
        self.id = id; self.request = request
        drafts = Dictionary(uniqueKeysWithValues: request.columns.map { ($0.id, $0.initialDraft) })
    }
    func set(_ draft: WorkspaceDatabaseDataRowInsertDraft, column: String) { drafts[column] = draft; edited.insert(column) }
    func insert() -> WorkspaceDatabaseDataRowInsert { request.makeInsert(drafts: drafts, includedColumnNames: edited) }
}

struct MobilePendingInsert: Identifiable {
    let id: UUID
    let request: WorkspaceDatabaseDataRowInsertRequest
    let drafts: [String: WorkspaceDatabaseDataRowInsertDraft]
    let edited: Set<String>
    var value: WorkspaceDatabaseDataRowInsert { request.makeInsert(drafts: drafts, includedColumnNames: edited) }
}

/// Per-object staging survives table/page/filter navigation; raw PKs never come
/// from timestamp display or the pending visible value of an edited primary key.
@MainActor @Observable final class MobileTableChanges: Identifiable {
    let id = UUID()
    let object: MobileDatabaseObject
    let safetyLock: WorkspaceSafetyLock
    let isQueryResult: Bool
    private(set) var revision = UUID()
    private(set) var updates: [WorkspaceDatabaseDataCellUpdate] = []
    private(set) var inserts: [MobilePendingInsert] = []
    private(set) var deletes: [WorkspaceDatabaseDataRowDelete] = []
    private(set) var isSubmitting = false
    private(set) var needsVerification = false
    private(set) var requiresReload = false
    private(set) var message: String?
    private(set) var metadata: [MobileTableColumn]
    private var stagedMetadata: [MobileTableColumn]?
    private let configuration: MobileSQLConfiguration
    private let service: any MobileDataMutating
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var didCommit: (() -> Void)?
    @ObservationIgnored var didApply: ((WorkspaceDatabaseDataChangeSet) -> Void)?
    @ObservationIgnored var didDiscardUncertain: (() -> Void)?
    @ObservationIgnored var isContextCurrent: @MainActor () -> Bool = { true }

    init(object: MobileDatabaseObject, metadata: [MobileTableColumn], configuration: MobileSQLConfiguration,
         safetyLock: WorkspaceSafetyLock, service: any MobileDataMutating = MobileDataMutationService(), isQueryResult: Bool = false) {
        self.object = object; self.metadata = metadata; self.configuration = configuration
        self.safetyLock = safetyLock; self.service = service
        self.isQueryResult = isQueryResult
    }
    var hasChanges: Bool { !updates.isEmpty || !inserts.isEmpty || !deletes.isEmpty }
    var changeCount: Int { changeSet.rowUpdates.count + inserts.count + deletes.count }
    var changeSet: WorkspaceDatabaseDataChangeSet {
        .init(updates: updates.filter { update in !deletes.contains { $0.conditions == update.primaryKey } },
              inserts: inserts.map(\.value), deletes: deletes)
    }
    var canSubmit: Bool { isContextCurrent() && hasChanges && !isSubmitting && !needsVerification && !requiresReload && (stagedMetadata == nil || stagedMetadata == metadata) }
    var editingRestriction: String? {
        if needsVerification { return MobileDataMutationError.uncertainCommit.localizedDescription }
        return requiresReload ? "当前数据尚未核对，刷新成功后才能继续修改。" : nil
    }
    func requireSuccessfulReload() {
        requiresReload = true; message = editingRestriction; revision = UUID()
    }
    func receive(metadata: [MobileTableColumn]) {
        self.metadata = metadata
        // Called only after a successful table data reload, never a failed
        // refresh or the act of discarding an uncertain draft.
        if requiresReload, !hasChanges { requiresReload = false; message = nil; revision = UUID() }
        if hasChanges, stagedMetadata != metadata { message = WorkspaceDatabaseDataCellEditError.editingContextChanged.localizedDescription }
    }
    private func validate() throws {
        guard isContextCurrent(), !isSubmitting, !needsVerification, !requiresReload, object.kind == .table,
              stagedMetadata == nil || stagedMetadata == metadata else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
    }
    private func changed() { stagedMetadata = hasChanges ? (stagedMetadata ?? metadata) : nil; revision = UUID(); message = nil }
    func row(_ index: Int, page: MobileTableSnapshot) throws -> WorkspaceDatabaseDataRow {
        guard page.object == object, page.preview.result.rows.indices.contains(index), page.columns == metadata else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        let grid = MobileGridData(preview: page.preview)
        return .init(id: index, values: grid.columns.indices.map { grid.cell(row: index, column: $0) })
    }
    func request(page: MobileTableSnapshot, row index: Int, column: Int) throws -> WorkspaceDatabaseDataCellEditRequest {
        try validate()
        let row = try row(index, page: page)
        var target = WorkspaceDatabaseDataCellEditTarget(rowIndex: index, dataColumnIndex: column, columns: page.preview.workspaceColumns, row: row)
        if isQueryResult {
            target = try WorkspaceQueryResultEditing.editTarget(selection: object.editingSelection, target: target, metadata: metadata.map(\.editingColumn))
        }
        let request = try WorkspaceDatabaseDataCellEditRequest.make(selection: object.editingSelection, target: target,
            columns: metadata.map(\.editingColumn))
        guard !deletes.contains(where: { $0.conditions == request.primaryKey }) else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        if let pending = updates.first(where: { $0.primaryKey == request.primaryKey && $0.columnName == request.column.name }) {
            return .init(selection: request.selection, column: request.column, originalValue: pending.originalValue,
                         initialValue: pending.newValue, primaryKey: request.primaryKey)
        }
        return request
    }
    func usesDefault(_ request: WorkspaceDatabaseDataCellEditRequest) -> Bool {
        updates.contains { $0.primaryKey == request.primaryKey && $0.columnName == request.column.name && $0.assignment == .useDefault }
    }
    func stage(_ request: WorkspaceDatabaseDataCellEditRequest, text: String, mode: WorkspaceDatabaseDataRowInsertMode) throws {
        try validate()
        guard request.selection == object.editingSelection, metadata.map(\.editingColumn).contains(request.column) else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        let update = try mode == .useDefault ? request.makeDefaultUpdate() : request.makeUpdate(text: text, usesNull: mode == .null)
        updates.removeAll { $0.columnName == update.columnName && $0.primaryKey == update.primaryKey }
        if update.assignment == .useDefault || update.newValue != update.originalValue { updates.append(update) }
        changed()
    }
    func toggleDelete(page: MobileTableSnapshot, row index: Int) throws {
        try validate()
        let row = try row(index, page: page), columns = page.preview.workspaceColumns
        let deletion = try isQueryResult
            ? WorkspaceQueryResultEditing.deleteRequest(selection: object.editingSelection, row: row, columns: columns, metadata: metadata.map(\.editingColumn))
            : WorkspaceDatabaseDataRowDeleteRequest.make(selection: object.editingSelection, row: row, columns: columns, metadata: metadata.map(\.editingColumn))
        if deletes.contains(deletion) { deletes.removeAll { $0 == deletion } } else { deletes.append(deletion) }
        changed()
    }
    func newInsert() throws -> MobileInsertDraft {
        try validate()
        guard !isQueryResult else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
        return .init(request: try .make(selection: object.editingSelection, columns: metadata.map(\.editingColumn)))
    }
    func stage(_ draft: MobileInsertDraft) throws {
        try validate()
        guard draft.request.selection == object.editingSelection,
              draft.request.columns == (try WorkspaceDatabaseDataRowInsertRequest.make(selection: object.editingSelection, columns: metadata.map(\.editingColumn))).columns else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        let pending = MobilePendingInsert(id: draft.id, request: draft.request, drafts: draft.drafts, edited: draft.edited)
        if let index = inserts.firstIndex(where: { $0.id == draft.id }) { inserts[index] = pending }
        else { inserts.append(pending) }
        changed()
    }
    func editInsert(_ insert: MobilePendingInsert) throws -> MobileInsertDraft {
        try validate()
        let draft = MobileInsertDraft(request: insert.request, id: insert.id)
        draft.drafts = insert.drafts; draft.edited = insert.edited
        return draft
    }
    func removeInsert(_ id: UUID) {
        guard !isSubmitting, !needsVerification else { return }
        inserts.removeAll { $0.id == id }; changed()
    }
    func discard() {
        guard !isSubmitting else { return }
        let refresh = needsVerification
        requiresReload = requiresReload || refresh
        updates = []; inserts = []; deletes = []; stagedMetadata = nil; needsVerification = false; message = editingRestriction; revision = UUID()
        if refresh { didDiscardUncertain?(); didCommit?() }
    }
    func previewSQL() throws -> String {
        let changes = changeSet
        if configuration.driver == .postgresql, let schema = object.schemaName {
            return try PostgreSQLDataMutation.preview(changes, table: .init(schema: schema, name: object.name))
        }
        let deletes = try changes.deletes.map { try MySQLWorkspaceDataRowDeleteStatement.make(delete: $0).previewTokens.map(\.text).joined() }
        let updates = try changes.rowUpdates.map { try MySQLWorkspaceDataCellUpdateStatement.make(rowUpdate: $0).previewTokens.map(\.text).joined() }
        let inserts = try changes.inserts.map { try MySQLWorkspaceDataRowInsertStatement.make(insert: $0).previewSQL }
        return (deletes + updates + inserts).joined(separator: "\n\n")
    }
    @discardableResult func submit() -> Task<Void, Never>? {
        guard canSubmit else { return nil }
        guard !safetyLock.isEnabled else { message = WorkspaceDatabaseDataCellEditError.safetyLockEnabled.localizedDescription; return nil }
        let changes = changeSet, configuration = configuration, service = service.scoped(to: object, columns: metadata)
        isSubmitting = true; message = nil
        // A short system lease lets a background cancellation finish rollback
        // and close its socket. It never schedules or replays a write.
        let lifetime = UIApplication.shared.beginBackgroundTask(withName: "Finish database transaction") { [weak self] in
            Task { @MainActor [weak self] in self?.interruptSubmission() }
        }
        let task = Task { [self] in
            defer { if lifetime != .invalid { UIApplication.shared.endBackgroundTask(lifetime) } }
            do {
                try await service.apply(changes, configuration: configuration) { [weak self] in
                    try await MainActor.run {
                        guard let self, !self.safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
                        guard self.isContextCurrent(), self.stagedMetadata == self.metadata else {
                            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
                        }
                    }
                }
                isSubmitting = false; self.task = nil
                didApply?(changes)
                discard(); didCommit?()
            } catch {
                isSubmitting = false; self.task = nil; message = MobileConnectionFeedback.writing(error)
                if case MobileDataMutationError.uncertainCommit = error { needsVerification = true }
            }
        }
        self.task = task; return task
    }

    func interruptSubmission() {
        // Keep the submission exclusive until its transaction has closed. A
        // COMMIT already in flight is classified as uncertain by the service.
        safetyLock.enable()
        task?.cancel()
    }
}


extension MobileTableChanges {
    func displayData(page: MobileTableSnapshot, details: [String]?) -> MobileGridData {
        let original = MobileGridData(preview: page.preview, details: details)
        guard hasChanges else { return original }
        var cells = original.rows.indices.map { row in original.columns.indices.map { original.cell(row: row, column: $0) } }
        var pending = Set<MobileGridCellAddress>(), deleted = Set<Int>()
        let columns = page.preview.workspaceColumns
        for row in original.rows.indices {
            func matches(_ key: [WorkspaceDatabaseDataCellUpdateCondition]) -> Bool {
                key.allSatisfy { condition in
                    guard let column = columns.first(where: { sourceName($0) == condition.columnName }) else { return false }
                    return original.cell(row: row, column: column.id) == condition.value
                }
            }
            if deletes.contains(where: { matches($0.conditions) }) { deleted.insert(row) }
            for update in updates where matches(update.primaryKey) {
                for column in columns where sourceName(column) == update.columnName {
                    cells[row][column.id] = update.assignment == .useDefault ? .text("DEFAULT") : update.newValue
                    pending.insert(.init(row: row, column: column.id))
                }
            }
        }
        var result = MobileGridData(columns: original.columns, details: original.details, rows: original.rows,
            cells: cells, metadata: original.metadata)
        result.pendingCells = pending; result.deletedRows = deleted
        return result
    }

    private func sourceName(_ column: WorkspaceDatabaseDataColumn) -> String? {
        column.origin?.columnName ?? (isQueryResult ? nil : column.name)
    }
}
