import Foundation
import Observation
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport

@MainActor @Observable final class MobileSchemaDraft: Identifiable {
    let id = UUID()
    let object: MobileDatabaseObject
    private(set) var state = WorkspaceDatabaseSchemaEditorState()
    private(set) var snapshot: MobileSchemaSnapshot?
    private(set) var epoch = UUID()
    private(set) var revision = UUID()
    var selectedID: UUID?
    var section: Section = .columns
    var presentation: Presentation = .table
    var needsVerification = false
    var requiresReload = false
    var message: String?
    var isError = false
    enum Section: String, CaseIterable { case columns = "字段", indexes = "索引" }
    enum Presentation: String, CaseIterable { case table = "表格", list = "列表" }
    init(object: MobileDatabaseObject) { self.object = object }
    var hasChanges: Bool { state.hasChanges }
    var changeSet: WorkspaceDatabaseSchemaChangeSet { .init(selection: object.editingSelection, columns: state.columns, indexes: state.indexes, tableOptionsChange: state.tableOptionsChange) }
    var plan: WorkspaceDatabaseSchemaExecutionPlan { MySQLSchemaEditingProvider().makeExecutionPlan(for: changeSet) }
    func receive(_ snapshot: MobileSchemaSnapshot) {
        let selectedName = section == .columns ? state.columns.first { $0.id == selectedID }?.original?.name : state.indexes.first { $0.id == selectedID }?.original?.name
        self.snapshot = snapshot; state.reset(columns: snapshot.columns, indexes: snapshot.indexes, schemaChoices: snapshot.choices, tableOptions: snapshot.options)
        needsVerification = false; requiresReload = false; message = nil; isError = false; epoch = UUID(); revision = UUID()
        selectedID = section == .columns ? state.columns.first { $0.original?.name == selectedName }?.id : state.indexes.first { $0.original?.name == selectedName }?.id
    }
    func discard() { state.discardChanges(); epoch = UUID(); revision = UUID(); selectedID = nil; message = nil; isError = false }
    func updateColumn(_ id: UUID, definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition, primary: Bool) {
        state.updateColumn(id: id, definition: definition); state.setPrimaryKey(columnID: id, isEnabled: primary); revision = UUID()
    }
    func updateOptions(_ options: WorkspaceDatabaseTableOptions) {
        guard snapshot?.options != nil, !needsVerification, !requiresReload else { return }
        state.tableOptions = options; revision = UUID()
    }
    func updateIndex(_ id: UUID, definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition) { state.updateIndex(id: id, definition: definition); revision = UUID() }
    func add() -> UUID {
        let id = section == .columns ? state.addColumn(defaultType: MySQLSchemaEditingProvider().descriptor.defaultColumnType) : state.addIndex()
        revision = UUID(); selectedID = id; return id
    }
    func delete(_ id: UUID) {
        selectedID = section == .columns ? state.deleteColumn(id: id) : state.deleteIndex(id: id)
        revision = UUID()
    }
    func restore(_ id: UUID) {
        // Original values/identities stay in the shared editor; undo a staged deletion in place.
        state.restoreDeletion(id: id); revision = UUID()
    }
}

@MainActor @Observable final class MobileSchemaController {
    private(set) var drafts: [String: MobileSchemaDraft] = [:]
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var loadingObjectID: String?
    let safetyLock: WorkspaceSafetyLock
    @ObservationIgnored var contextID: () -> UUID = { UUID() }
    @ObservationIgnored var isCurrent: (MobileDatabaseObject) -> Bool = { _ in false }
    @ObservationIgnored var hasPendingData: (MobileDatabaseObject) -> Bool = { _ in true }
    @ObservationIgnored var didRead: (MobileDatabaseObject, MobileSchemaSnapshot) -> Void = { _, _ in }
    @ObservationIgnored var didApply: (MobileDatabaseObject) -> Void = { _ in }
    @ObservationIgnored var allowsWrites: () -> Bool = { false }
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    private let configuration: MobileSQLConfiguration
    private let service: any MobileSchemaServicing
    init(configuration: MobileSQLConfiguration, safetyLock: WorkspaceSafetyLock, service: any MobileSchemaServicing = MobileSchemaService()) {
        self.configuration = configuration; self.safetyLock = safetyLock; self.service = service
    }
    var hasPendingChanges: Bool { isSubmitting || drafts.values.contains { $0.hasChanges || $0.needsVerification || $0.requiresReload } }
    var blocksWrites: Bool { isSubmitting || drafts.values.contains { $0.needsVerification } }
    func sqlDidWrite() {
        cancelRead()
        for draft in drafts.values {
            draft.requiresReload = true
            draft.message = "SQL 已执行写入，使用顶部刷新核对结构后再编辑。"
        }
    }
    func draft(for object: MobileDatabaseObject) -> MobileSchemaDraft {
        if let value = drafts[object.id] { return value }
        let value = MobileSchemaDraft(object: object); drafts[object.id] = value; return value
    }
    func canEdit(_ draft: MobileSchemaDraft) -> Bool {
        draft.snapshot != nil && draft.object.kind == .table && isCurrent(draft.object) && !isSubmitting && !isLoading
            && !blocksWrites && !draft.needsVerification && !draft.requiresReload && allowsWrites() && !hasPendingData(draft.object)
    }
    @discardableResult func load(_ object: MobileDatabaseObject, reconcile: Bool = false) -> Task<Void, Never>? {
        guard !isSubmitting, isCurrent(object) else { return nil }
        let draft = draft(for: object)
        guard reconcile || !draft.needsVerification else { draft.message = "结果待核对。核对后使用“重新加载结构”结束此次操作。"; return nil }
        guard reconcile || !draft.hasChanges || draft.requiresReload else { draft.message = "先提交或撤销结构改动，再刷新。"; return nil }
        readTask?.cancel(); let id = UUID(); let context = contextID(); loadID = id; isLoading = true; loadingObjectID = object.id; draft.message = nil; draft.isError = false
        let task = Task { [weak self, service, configuration] in
            do {
                let snapshot = try await service.load(object: object, configuration: configuration); try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                self.isLoading = false; self.loadingObjectID = nil; self.readTask = nil
                guard self.contextID() == context, self.isCurrent(object) else { return }
                draft.receive(snapshot); self.didRead(object, snapshot)
            } catch {
                guard let self, self.loadID == id else { return }
                self.isLoading = false; self.loadingObjectID = nil; self.readTask = nil
                if !(error is CancellationError) { draft.isError = true; draft.message = MobileConnectionFeedback.reading(error) }
            }
        }
        readTask = task; return task
    }
    @discardableResult func submit(_ draft: MobileSchemaDraft, expectedPlan: WorkspaceDatabaseSchemaExecutionPlan? = nil) -> Task<Void, Never>? {
        guard canEdit(draft), draft.hasChanges, !safetyLock.isEnabled, let baseline = draft.snapshot else { return nil }
        let plan = draft.plan
        guard expectedPlan == nil || expectedPlan == plan, !plan.statements.isEmpty else { return nil }
        let epoch = draft.epoch; let context = contextID()
        isSubmitting = true; draft.message = nil; draft.isError = false
        let lifetime = UIApplication.shared.beginBackgroundTask(withName: "Finish schema operation") { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        let task = Task { [self, service, configuration] in
            defer { isSubmitting = false; writeTask = nil; if lifetime != .invalid { UIApplication.shared.endBackgroundTask(lifetime) } }
            do {
                try await service.apply(object: draft.object, baseline: baseline, plan: plan, configuration: configuration) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.isCurrent(draft.object), self.contextID() == context, draft.epoch == epoch, draft.plan == plan, self.allowsWrites() else { throw MobileSchemaError.stale }
                        guard !self.hasPendingData(draft.object) else { throw MobileSchemaError.pending }
                        guard !self.safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
                    }
                }
                draft.requiresReload = true; draft.message = "结构已提交，使用顶部刷新读取最新结构。"; didApply(draft.object)
                if isCurrent(draft.object) {
                    do {
                        let snapshot = try await service.load(object: draft.object, configuration: configuration)
                        guard isCurrent(draft.object), contextID() == context else { return }; draft.receive(snapshot); didRead(draft.object, snapshot); draft.message = "结构已更新"
                    } catch { draft.isError = true; draft.message = "结构已提交，读取失败。请使用顶部刷新，无需重复提交。\n" + error.localizedDescription }
                }
            } catch {
                if case MobileSchemaError.partial = error {
                    draft.needsVerification = true; safetyLock.enable(); didApply(draft.object)
                }
                draft.isError = true; draft.message = MobileConnectionFeedback.writing(error)
            }
        }
        writeTask = task; return task
    }
    func cancelRead() {
        loadID = UUID(); readTask?.cancel(); readTask = nil; isLoading = false; loadingObjectID = nil
    }
    func cancel() { cancelRead(); safetyLock.enable(); writeTask?.cancel() }
}
