import SwiftUI
import Observation
import QueryCraftMobileCore

struct MobileResultSourceIdentity: Equatable {
    let widthKey: String
    let timestampScope: String?
    let page: MobileGridPageContext?
}

struct MobileResultSnapshot {
    let data: MobileGridData
    let revision: String
    let dataRevision: String
    let identity: MobileResultSourceIdentity
    var editing: MobileTableChanges? = nil
    var page: MobileTableSnapshot? = nil
    var isLoading = false
    var readOnlyReason: String? = nil
}

/// Presentation adapter only: mutation rules, original keys, preview and commit
/// remain owned by the same table/query changes model as the ordinary grid.
@MainActor @Observable final class MobileResultSource {
    private(set) var snapshot: MobileResultSnapshot
    private(set) var generation = UUID()
    private(set) var isCurrent = true

    init(_ snapshot: MobileResultSnapshot) { self.snapshot = snapshot }

    var data: MobileGridData {
        guard let changes = snapshot.editing, let page = snapshot.page else { return snapshot.data }
        return changes.displayData(page: page, details: snapshot.data.details)
    }
    var revision: String { snapshot.revision + (snapshot.editing?.revision.uuidString ?? "") }
    var canEdit: Bool {
        isCurrent && !snapshot.isLoading && snapshot.readOnlyReason == nil && snapshot.editing != nil && snapshot.page != nil
            && snapshot.editing?.editingRestriction == nil && snapshot.editing?.isSubmitting == false
    }

    func receive(_ snapshot: MobileResultSnapshot) {
        guard isCurrent else { return }
        guard self.snapshot.identity == snapshot.identity else { invalidate(); return }
        if self.snapshot.dataRevision != snapshot.dataRevision { generation = UUID() }
        self.snapshot = snapshot
    }
    func invalidate() { isCurrent = false; generation = UUID() }
    func validate(_ generation: UUID) throws {
        guard isCurrent, self.generation == generation, canEdit else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
    }
    func edit(row: Int, column: Int) throws -> MobileCellEditingPresentation {
        try validate(generation)
        guard let changes = snapshot.editing, let page = snapshot.page else { throw WorkspaceDatabaseDataCellEditError.metadataUnavailable }
        let generation = generation
        return .init(request: try changes.request(page: page, row: row, column: column), changes: changes, page: page, row: row,
                     validateContext: { [weak self] in
                         guard let self else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
                         try self.validate(generation)
                     })
    }
    func cell(row: Int, column: Int) -> MobileResultCellPresentation? {
        let data = data
        guard data.rows.indices.contains(row), data.columns.indices.contains(column) else { return nil }
        do { return .init(content: .edit(try edit(row: row, column: column))) }
        catch {
            let reason = snapshot.editing?.editingRestriction ?? snapshot.readOnlyReason ?? (snapshot.editing != nil || !isCurrent ? error.localizedDescription : nil)
            return .init(content: .inspect(.init(row: row, column: column, name: data.columns[column], value: data.cell(row: row, column: column)), reason))
        }
    }
}

struct MobileResultCellPresentation: Identifiable {
    enum Content {
        case edit(MobileCellEditingPresentation)
        case inspect(MobileCellSelection, String?)
    }
    let id = UUID()
    let content: Content
}

struct MobileResultCellSheet: View {
    let presentation: MobileResultCellPresentation
    var body: some View {
        switch presentation.content {
        case .edit(let captured):
            MobileCellEditView(request: captured.request, changes: captured.changes, validateContext: captured.validateContext) {
                try captured.changes.toggleDelete(page: captured.page, row: captured.row)
            }
        case .inspect(let cell, let reason): MobileCellInspector(selection: cell, editingMessage: reason)
        }
    }
}
