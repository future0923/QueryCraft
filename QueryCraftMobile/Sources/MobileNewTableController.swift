import Foundation
import Observation
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport

@MainActor @Observable final class MobileNewTableDraft: Identifiable {
    let id = UUID()
    let definition: WorkspaceNewTableDraft
    let epoch = UUID()
    var hasCompleted = false
    var needsVerification = false
    var message: String?
    var choicesError: String?
    init(database: String) {
        definition = .init(databaseName: database, schemaEditingDescriptor: MySQLSchemaEditingProvider().descriptor)
    }
    var plan: WorkspaceDatabaseSchemaExecutionPlan { MySQLSchemaEditingProvider().makeExecutionPlan(for: definition.mutation) }
    var isValid: Bool {
        !definition.tableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !definition.tableName.contains("\0")
            && definition.editor.columns.contains { !$0.isDeleted }
            && definition.editor.columns.filter { !$0.isDeleted }.allSatisfy { !$0.definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.definition.type.isEmpty }
    }
}

@MainActor @Observable final class MobileNewTableController {
    private(set) var draft: MobileNewTableDraft?
    var request: MobileNewTableDraft?
    private(set) var isSubmitting = false
    private(set) var isLoadingChoices = false
    let safetyLock: WorkspaceSafetyLock
    var hasPendingChanges: Bool { isSubmitting || draft.map { !$0.hasCompleted || $0.needsVerification } == true }
    var blocksWrites: Bool { isSubmitting || draft?.needsVerification == true }
    @ObservationIgnored var isCurrent: (String) -> Bool = { _ in false }
    @ObservationIgnored var contextID: () -> UUID = { UUID() }
    @ObservationIgnored var allowsWrites: () -> Bool = { false }
    @ObservationIgnored var didComplete: (MobileDatabaseObject) async -> String? = { _ in nil }
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    private let configuration: MobileSQLConfiguration
    private let service: any MobileNewTableServicing
    init(configuration: MobileSQLConfiguration, safetyLock: WorkspaceSafetyLock, service: any MobileNewTableServicing = MobileNewTableService()) {
        self.configuration = configuration; self.safetyLock = safetyLock; self.service = service
    }

    func present(database: String) {
        guard !isSubmitting, isCurrent(database) else { return }
        if draft == nil { draft = MobileNewTableDraft(database: database) }
        request = draft
    }
    func dismiss() { guard !isSubmitting else { return }; cancelRead(); request = nil; if draft?.hasCompleted == true { draft = nil } }
    func discard(_ draft: MobileNewTableDraft) {
        guard self.draft === draft, !isSubmitting, !draft.needsVerification else { return }
        cancelRead(); request = nil; self.draft = nil
    }
    func acknowledgeVerification(_ draft: MobileNewTableDraft) {
        guard self.draft === draft, !isSubmitting, draft.needsVerification else { return }
        safetyLock.enable(); request = nil; self.draft = nil
    }
    func canEdit(_ draft: MobileNewTableDraft) -> Bool {
        self.draft === draft && !isSubmitting && !draft.hasCompleted && !draft.needsVerification && isCurrent(draft.definition.databaseName)
    }
    func editingContext(_ draft: MobileNewTableDraft) -> MobileSchemaEditingContext {
        .init(readState: { draft.definition.editor }, readEpoch: { draft.epoch }, allowsEditing: { [weak self] in self?.canEdit(draft) == true },
            updateColumn: { id, definition, primary in
                draft.definition.editor.updateColumn(id: id, definition: definition)
                draft.definition.editor.setPrimaryKey(columnID: id, isEnabled: primary)
            }, updateIndex: { draft.definition.editor.updateIndex(id: $0, definition: $1) },
            delete: { id in
                if draft.definition.editor.columns.contains(where: { $0.id == id }) { _ = draft.definition.editor.deleteColumn(id: id) }
                else { _ = draft.definition.editor.deleteIndex(id: id) }
            })
    }
    @discardableResult func loadChoices(_ draft: MobileNewTableDraft) -> Task<Void, Never>? {
        guard canEdit(draft) else { return nil }
        cancelRead(); let id = UUID(), context = contextID(); loadID = id; isLoadingChoices = true; draft.choicesError = nil
        let task = Task { [weak self, service, configuration] in
            do {
                let choices = try await service.choices(configuration: .init(host: configuration.host, port: configuration.port,
                    username: configuration.username, password: configuration.password, database: draft.definition.databaseName, tlsMode: configuration.tlsMode))
                try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                self.isLoadingChoices = false; self.readTask = nil
                guard self.draft === draft, self.contextID() == context, self.canEdit(draft) else { return }
                draft.definition.editor.updateSchemaChoices(choices)
            } catch {
                guard let self, self.loadID == id else { return }
                self.isLoadingChoices = false; self.readTask = nil
                if !(error is CancellationError) { draft.choicesError = MobileConnectionFeedback.reading(error) }
            }
        }
        readTask = task; return task
    }
    @discardableResult func submit(_ draft: MobileNewTableDraft, plan: WorkspaceDatabaseSchemaExecutionPlan) -> Task<Void, Never>? {
        guard canEdit(draft), draft.isValid, !safetyLock.isEnabled, allowsWrites(), plan == draft.plan else { return nil }
        cancelRead(); let context = contextID(); isSubmitting = true; draft.message = nil
        let lifetime = UIApplication.shared.beginBackgroundTask(withName: "Finish table creation") { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        let task = Task { [self, service, configuration] in
            defer { isSubmitting = false; writeTask = nil; if lifetime != .invalid { UIApplication.shared.endBackgroundTask(lifetime) } }
            do {
                let selection = try await service.create(plan: plan, configuration: configuration) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.draft === draft, self.isCurrent(draft.definition.databaseName), self.contextID() == context,
                              draft.plan == plan, self.allowsWrites() else { throw MobileSchemaError.stale }
                        guard !self.safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
                    }
                }
                draft.hasCompleted = true // Fence replay before any read/navigation await.
                draft.message = "表已创建，使用顶部刷新读取最新目录。"
                if isCurrent(draft.definition.databaseName), contextID() == context {
                    let comment: String
                    if case .tableMutation(.create(_, _, _, _, let options)) = plan.source { comment = options.comment } else { comment = "" }
                    let object = MobileDatabaseObject(database: selection.databaseName, name: selection.objectName, kind: .table, comment: comment)
                    let warning = await didComplete(object)
                    draft.message = warning ?? "表已创建"
                    if warning == nil, request === draft { request = nil; self.draft = nil }
                }
            } catch {
                if case MobileNewTableError.outcomeUnknown = error { draft.needsVerification = true; safetyLock.enable() }
                draft.message = MobileConnectionFeedback.writing(error)
            }
        }
        writeTask = task; return task
    }
    func cancelRead() { loadID = UUID(); readTask?.cancel(); readTask = nil; isLoadingChoices = false }
    func cancel() { cancelRead(); safetyLock.enable(); writeTask?.cancel() }
}
