import Foundation
import Observation
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport

@MainActor @Observable final class MobileTableActionDraft: Identifiable {
    let id = UUID()
    let action: WorkspaceTableAction
    let object: MobileDatabaseObject
    let contextID: UUID
    var input: String
    var confirmation = ""
    private(set) var hasCompleted = false
    private(set) var needsVerification = false
    var message: String?
    var info: MobileTableActionInfo?
    var isInspecting = false
    init(action: WorkspaceTableAction, object: MobileDatabaseObject, contextID: UUID) {
        self.action = action; self.object = object; self.contextID = contextID
        input = action == .rename ? object.name : "1"
    }
    var statement: WorkspaceTableActionStatement? {
        try? .make(action: action, selection: object.editingSelection, databaseType: .mysql, input: input)
    }
    var isConfirmed: Bool { !action.isDestructive || confirmation == object.name }
    var canSubmit: Bool { !hasCompleted && !needsVerification && isConfirmed && statement != nil }
    func completed(_ warning: String?) { hasCompleted = true; message = warning }
    func uncertain(_ error: any Error) { needsVerification = true; message = error.localizedDescription }
}

@MainActor @Observable final class MobileTableActionController {
    var request: MobileTableActionDraft?
    private(set) var isSubmitting = false
    private(set) var revision = UUID()
    private(set) var unverified: MobileTableActionDraft?
    var blocksWrites: Bool { isSubmitting || unverified != nil }
    let safetyLock: WorkspaceSafetyLock
    private let configuration: MobileSQLConfiguration
    private let service: any MobileTableActionServicing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var inspection: Task<Void, Never>?
    @ObservationIgnored var contextID: () -> UUID = { UUID() }
    @ObservationIgnored var isCurrent: (MobileTableActionDraft) -> Bool = { _ in false }
    @ObservationIgnored var hasPendingChanges: (MobileDatabaseObject) -> Bool = { _ in true }
    @ObservationIgnored var didComplete: (MobileDatabaseObject, WorkspaceTableActionStatement) async -> String? = { _, _ in nil }
    @ObservationIgnored var didBecomeUncertain: (MobileDatabaseObject) -> Void = { _ in }

    init(configuration: MobileSQLConfiguration, safetyLock: WorkspaceSafetyLock,
         service: any MobileTableActionServicing = MobileTableActionService()) {
        self.configuration = configuration; self.safetyLock = safetyLock; self.service = service
    }
    func prepare(_ action: WorkspaceTableAction, object: MobileDatabaseObject) {
        guard !isSubmitting, object.kind == .table else { return }
        if let unverified { request = unverified; return }
        inspection?.cancel()
        let draft = MobileTableActionDraft(action: action, object: object, contextID: contextID())
        guard isCurrent(draft) else { return }
        request = draft
    }
    func dismiss() { guard !isSubmitting else { return }; inspection?.cancel(); inspection = nil; request = nil }
    @discardableResult func inspect(_ draft: MobileTableActionDraft) -> Task<Void, Never>? {
        guard request === draft, isCurrent(draft), draft.action == .resetAutoIncrement || draft.action == .setAutoIncrement else { return nil }
        inspection?.cancel(); draft.isInspecting = true
        let operation = Task { [weak self, service, configuration] in
            defer { draft.isInspecting = false }
            do {
                let info = try await service.inspect(object: draft.object, configuration: configuration)
                try Task.checkCancellation()
                guard let self, self.request === draft, self.isCurrent(draft) else { return }
                draft.info = info
            } catch {
                guard let self, self.request === draft, self.isCurrent(draft), !(error is CancellationError) else { return }
                draft.message = MobileConnectionFeedback.reading(error)
            }
        }
        inspection = operation; return operation
    }
    @discardableResult func submit(_ draft: MobileTableActionDraft) -> Task<Void, Never>? {
        guard !isSubmitting, request === draft, draft.canSubmit, unverified == nil else { return nil }
        guard isCurrent(draft) else { draft.message = MobileTableActionError.contextChanged.localizedDescription; return nil }
        guard !hasPendingChanges(draft.object) else { draft.message = WorkspaceTableActionError.pendingChanges.localizedDescription; return nil }
        guard !safetyLock.isEnabled else { draft.message = WorkspaceDatabaseDataCellEditError.safetyLockEnabled.localizedDescription; return nil }
        let input = draft.input
        isSubmitting = true; draft.message = nil
        let lifetime = UIApplication.shared.beginBackgroundTask(withName: "Finish table operation") { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        let operation = Task { [self, service, configuration] in
            defer {
                isSubmitting = false; task = nil
                if lifetime != .invalid { UIApplication.shared.endBackgroundTask(lifetime) }
            }
            do {
                let statement = try await service.perform(action: draft.action, object: draft.object, input: input, configuration: configuration) { [weak self] in
                    try await MainActor.run {
                        guard let self, self.request === draft, self.isCurrent(draft) else { throw MobileTableActionError.contextChanged }
                        guard !self.hasPendingChanges(draft.object) else { throw WorkspaceTableActionError.pendingChanges }
                        guard !self.safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
                    }
                }
                draft.completed(nil) // Fence repeat writes before any refresh awaits.
                revision = UUID()
                let warning = await didComplete(draft.object, statement)
                draft.completed(warning)
                if warning == nil, request === draft { request = nil }
            } catch {
                if case MobileTableActionError.outcomeUnknown = error {
                    unverified = draft; draft.uncertain(error); safetyLock.enable()
                    revision = UUID(); didBecomeUncertain(draft.object)
                } else { draft.message = MobileConnectionFeedback.writing(error) }
            }
        }
        task = operation; return operation
    }
    func acknowledgeVerification(_ draft: MobileTableActionDraft) {
        guard !isSubmitting, unverified === draft else { return }
        // Explicit acknowledgement only; closing/reopening or a successful
        // network probe cannot prove the outcome of an autocommitted DDL.
        unverified = nil; draft.completed(nil); request = nil; revision = UUID()
    }
    func cancel() { inspection?.cancel(); safetyLock.enable(); task?.cancel() }
}
