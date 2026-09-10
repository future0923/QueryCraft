import Foundation
import Observation

enum WorkspacePreparedDocumentChange: Equatable, Sendable {
    case creation(WorkspacePreparedDocumentCreation)
    case creations(first: WorkspacePreparedDocumentCreationRow, rest: [WorkspacePreparedDocumentCreationRow])
    case replacement(WorkspacePreparedDocumentReplacement)
    case partialUpdate(WorkspacePreparedDocumentPartialUpdate)
    case partialUpdates(first: WorkspacePreparedDocumentPartialUpdate, rest: [WorkspacePreparedDocumentPartialUpdate])
    case deletion(WorkspacePreparedDocumentDeletion)
    case deletions(first: WorkspacePreparedDocumentDeletion, rest: [WorkspacePreparedDocumentDeletion])

    var deletions: [WorkspacePreparedDocumentDeletion] {
        switch self {
        case .deletion(let deletion): [deletion]
        case .deletions(let first, let rest): [first] + rest
        default: []
        }
    }

    var requests: [WorkspaceRequest] {
        if case .creations(let first, let rest) = self {
            return ([first] + rest).map { $0.creation.request }
        }
        if case .partialUpdates(let first, let rest) = self {
            return ([first] + rest).map(\.request)
        }
        let deletions = deletions
        return deletions.isEmpty ? [request] : deletions.map(\.request)
    }

    var isDeletion: Bool {
        switch self {
        case .deletion, .deletions: true
        default: false
        }
    }

    var request: WorkspaceRequest {
        switch self {
        case .creation(let creation): creation.request
        case .creations(let first, _): first.creation.request
        case .replacement(let replacement): replacement.request
        case .partialUpdate(let update): update.request
        case .partialUpdates(let first, _): first.request
        case .deletion(let deletion): deletion.request
        case .deletions(let first, _): first.request
        }
    }

    var reference: WorkspaceDocumentReference {
        switch self {
        case .creation(let creation):
            WorkspaceDocumentReference(
                index: creation.draft.targetName,
                id: creation.draft.id ?? "",
                routing: creation.draft.routing
            )
        case .creations(let first, _):
            WorkspaceDocumentReference(index: first.creation.draft.targetName,
                id: first.creation.draft.id ?? "", routing: first.creation.draft.routing)
        case .replacement(let replacement): replacement.draft.reference
        case .partialUpdate(let update): update.draft.reference
        case .partialUpdates(let first, _): first.draft.reference
        case .deletion(let deletion): deletion.draft.reference
        case .deletions(let first, _): first.draft.reference
        }
    }

    var sourceJSON: Data? {
        switch self {
        case .creation(let creation): creation.draft.sourceJSON
        case .creations(let first, _): first.creation.draft.sourceJSON
        case .replacement(let replacement): replacement.draft.sourceJSON
        case .partialUpdate(let update): update.draft.sourceJSON
        case .partialUpdates(let first, _): first.draft.sourceJSON
        case .deletion, .deletions: nil
        }
    }
}

@MainActor
@Observable
final class WorkspaceElasticsearchDocumentInspectorModel {
    enum State: Equatable {
        case empty
        case loading(WorkspaceDocumentReference)
        case loaded(WorkspaceDocumentSnapshot)
        case failed(WorkspaceDocumentReference, String)
    }

    enum EditingState: Equatable {
        case viewing
        case creating
        case editing
        case conflicted
        case deletionConflicted
    }

    private(set) var state = State.empty
    private(set) var isLoading = false
    private(set) var editingState = EditingState.viewing
    let cellChanges = WorkspaceElasticsearchCellChangesModel()
    let creations = WorkspaceElasticsearchDocumentCreationsModel()
    private var singleValidationErrorMessage: String?
    private var singlePreparedChange: WorkspacePreparedDocumentChange?
    private var singleIsValidating = false
    private(set) var validationErrorMessage: String? {
        get { creations.errorMessage ?? cellChanges.errorMessage ?? singleValidationErrorMessage }
        set { singleValidationErrorMessage = newValue }
    }
    private(set) var preparedChange: WorkspacePreparedDocumentChange? {
        get {
            if creations.hasChanges {
                guard let rows = creations.preparedRows, let first = rows.first else { return nil }
                return .creations(first: first, rest: Array(rows.dropFirst()))
            }
            if cellChanges.hasChanges {
                guard let updates = cellChanges.preparedUpdates, let first = updates.first else { return nil }
                return .partialUpdates(first: first, rest: Array(updates.dropFirst()))
            }
            return singlePreparedChange
        }
        set { singlePreparedChange = newValue }
    }
    private(set) var isCommitting = false
    private(set) var isCommitOutcomeUncertain = false
    private(set) var isValidating: Bool {
        get { singleIsValidating || cellChanges.isValidating || creations.isValidating }
        set { singleIsValidating = newValue }
    }
    var draftText = ""
    var creationDocumentID = ""
    var creationRouting = ""
    private(set) var creationTargetName: String?
    private(set) var creationTargetKind: WorkspaceDocumentCreationTargetKind?

    @ObservationIgnored private let validator =
        WorkspaceElasticsearchDocumentValidator()
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var validationRevision = 0
    @ObservationIgnored private var loadRevision = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingReference: WorkspaceDocumentReference?
    @ObservationIgnored private var loadingServerRevision = 0

    var isEditing: Bool {
        editingState == .editing || editingState == .conflicted
    }

    var isCreating: Bool {
        editingState == .creating || creations.hasChanges
    }

    var isPendingDeletion: Bool {
        preparedChange?.isDeletion == true
    }

    var loadedSnapshot: WorkspaceDocumentSnapshot? {
        guard case .loaded(let snapshot) = state else { return nil }
        return snapshot
    }

    var hasChanges: Bool {
        if cellChanges.hasChanges { return true }
        if isCreating { return true }
        if isPendingDeletion { return true }
        guard isEditing, let snapshot = loadedSnapshot else { return false }
        return Data(draftText.utf8) != snapshot.sourceJSON
    }

    var blocksDocumentSelectionChanges: Bool {
        hasChanges && !isPendingDeletion && !cellChanges.hasChanges && !creations.hasChanges
    }

    var canBeginEditing: Bool {
        guard let snapshot = loadedSnapshot else { return false }
        return !snapshot.isTruncated
            && snapshot.sequenceNumber != nil
            && snapshot.primaryTerm != nil
            && !hasChanges
            && !isCommitting
            && !isLoading
    }

    var canCommit: Bool {
        guard hasChanges,
              let preparedChange,
              validationErrorMessage == nil,
              !isCommitOutcomeUncertain,
              !isCommitting
        else { return false }
        switch preparedChange {
        case .creation:
            return editingState == .creating
        case .creations:
            return !creations.isBlocked && !creations.isValidating
        case .replacement, .partialUpdate:
            return editingState == .editing
        case .partialUpdates:
            return !cellChanges.isBlocked && !cellChanges.isValidating
        case .deletion, .deletions:
            return editingState == .viewing
        }
    }

    var preparedCreation: WorkspacePreparedDocumentCreation? {
        guard case .creation(let creation) = preparedChange else { return nil }
        return creation
    }

    var preparedReplacement: WorkspacePreparedDocumentReplacement? {
        guard case .replacement(let replacement) = preparedChange else {
            return nil
        }
        return replacement
    }

    var preparedPartialUpdate: WorkspacePreparedDocumentPartialUpdate? {
        guard case .partialUpdate(let update) = preparedChange else {
            return nil
        }
        return update
    }

    var preparedDeletion: WorkspacePreparedDocumentDeletion? {
        preparedDeletions.first
    }

    var preparedDeletions: [WorkspacePreparedDocumentDeletion] {
        preparedChange?.deletions ?? []
    }

    func load(
        reference: WorkspaceDocumentReference?,
        serverRevision: Int = 0,
        fetch: @escaping @MainActor @Sendable (WorkspaceDocumentReference) async throws
            -> WorkspaceDocumentSnapshot
    ) async {
        if blocksDocumentSelectionChanges || isCommitting { return }
        if let reference, loadingReference == reference,
           loadingServerRevision == serverRevision, let loadTask {
            await loadTask.value
            return
        }
        cancelLoading()
        let revision = UUID()
        loadRevision = revision
        let preservesPendingDeletion = isPendingDeletion || cellChanges.hasChanges || creations.hasChanges
        guard let reference else {
            if !preservesPendingDeletion {
                discardChanges()
            }
            state = .empty
            return
        }
        if isEditing, reference == loadedSnapshot?.reference { return }
        if !preservesPendingDeletion {
            discardChanges()
        }
        // Keep the current document mounted while reading its replacement.
        if loadedSnapshot?.reference != reference { state = .loading(reference) }
        isLoading = true
        loadingReference = reference
        loadingServerRevision = serverRevision
        let task = Task { @MainActor in
            defer {
                if loadRevision == revision {
                    isLoading = false
                    loadTask = nil
                    loadingReference = nil
                }
            }
            do {
                let snapshot = try await fetch(reference)
                try Task.checkCancellation()
                guard loadRevision == revision else { return }
                guard snapshot.reference == reference else { throw WorkspaceDocumentEditingError.unavailable }
                state = .loaded(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard loadRevision == revision else { return }
                state = .failed(reference, error.localizedDescription)
            }
        }
        loadTask = task
        await task.value
    }

    func cancelLoading() {
        loadTask?.cancel()
        isLoading = false
        loadTask = nil
        loadingReference = nil
        loadRevision = UUID()
    }

    func beginEditing() throws {
        guard !hasChanges, !isCommitting, !isLoading else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        guard let snapshot = loadedSnapshot else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        guard !snapshot.isTruncated else {
            throw WorkspaceDocumentEditingError.sourceTooLarge(
                WorkspaceElasticsearchDocumentValidator.maximumByteCount
            )
        }
        guard snapshot.sequenceNumber != nil, snapshot.primaryTerm != nil else {
            throw WorkspaceDocumentEditingError.missingConcurrencyMetadata
        }
        draftText = String(data: snapshot.sourceJSON, encoding: .utf8) ?? ""
        validationErrorMessage = nil
        preparedChange = nil
        editingState = .editing
    }

    func beginCreating(
        targetName: String,
        targetKind: WorkspaceDocumentCreationTargetKind,
        sourceJSON: Data = Data("{}".utf8),
        routing: String? = nil,
        prepare: @escaping @MainActor @Sendable (
            WorkspaceDocumentCreationDraft
        ) async throws -> WorkspacePreparedDocumentCreation
    ) throws {
        guard !hasChanges, !isCommitting, !targetName.isEmpty else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        guard let sourceText = String(data: sourceJSON, encoding: .utf8) else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        creationTargetName = targetName
        creationTargetKind = targetKind
        creationDocumentID = ""
        creationRouting = routing ?? ""
        draftText = sourceText
        validationErrorMessage = nil
        preparedChange = nil
        editingState = .creating
        updateCreationDraft(
            documentID: creationDocumentID,
            routing: creationRouting,
            text: draftText,
            prepare: prepare
        )
    }

    func installPastedCreation(
        _ creation: WorkspacePreparedDocumentCreation, sourceText: String
    ) {
        creationTargetName = creation.draft.targetName
        creationTargetKind = creation.draft.targetKind
        creationDocumentID = creation.draft.id ?? ""
        creationRouting = creation.draft.routing ?? ""
        draftText = sourceText
        editingState = .creating
        preparedChange = .creation(creation)
    }

    func updateCreationDraft(
        documentID: String,
        routing: String,
        text: String,
        prepare: @escaping @MainActor @Sendable (
            WorkspaceDocumentCreationDraft
        ) async throws -> WorkspacePreparedDocumentCreation
    ) {
        creationDocumentID = documentID
        creationRouting = routing
        draftText = text
        validationRevision &+= 1
        let revision = validationRevision
        validationTask?.cancel()
        preparedChange = nil
        validationErrorMessage = nil
        isValidating = false

        guard editingState == .creating,
              let targetName = creationTargetName,
              let targetKind = creationTargetKind
        else { return }

        isValidating = true
        validationTask = Task { @MainActor [validator] in
            do {
                let sourceJSON = try await validator.validate(text)
                try Task.checkCancellation()
                let normalizedID = Self.optionalIdentity(documentID)
                let normalizedRouting = Self.optionalIdentity(routing)
                let draft = WorkspaceDocumentCreationDraft(
                    targetName: targetName,
                    targetKind: targetKind,
                    id: normalizedID,
                    routing: normalizedRouting,
                    sourceJSON: sourceJSON
                )
                let creation = try await prepare(draft)
                try Task.checkCancellation()
                guard validationRevision == revision,
                      creationDocumentID == documentID,
                      creationRouting == routing,
                      draftText == text,
                      editingState == .creating
                else { return }
                preparedChange = .creation(creation)
                isValidating = false
            } catch is CancellationError {
                return
            } catch {
                guard validationRevision == revision,
                      creationDocumentID == documentID,
                      creationRouting == routing,
                      draftText == text
                else { return }
                validationErrorMessage = error.localizedDescription
                isValidating = false
            }
        }
    }

    func updateDraft(
        _ text: String,
        prepare: @escaping @MainActor @Sendable (
            WorkspaceDocumentReplacementDraft
        ) async throws -> WorkspacePreparedDocumentReplacement
    ) {
        draftText = text
        validationRevision &+= 1
        let revision = validationRevision
        validationTask?.cancel()
        preparedChange = nil
        validationErrorMessage = nil
        isValidating = false

        guard hasChanges, editingState == .editing,
              let snapshot = loadedSnapshot,
              let sequenceNumber = snapshot.sequenceNumber,
              let primaryTerm = snapshot.primaryTerm
        else { return }

        isValidating = true
        validationTask = Task { @MainActor [validator] in
            do {
                let sourceJSON = try await validator.validate(text)
                try Task.checkCancellation()
                let draft = WorkspaceDocumentReplacementDraft(
                    reference: snapshot.reference,
                    sequenceNumber: sequenceNumber,
                    primaryTerm: primaryTerm,
                    sourceJSON: sourceJSON
                )
                let replacement = try await prepare(draft)
                try Task.checkCancellation()
                guard validationRevision == revision,
                      draftText == text,
                      editingState == .editing
                else { return }
                preparedChange = .replacement(replacement)
                isValidating = false
            } catch is CancellationError {
                return
            } catch {
                guard validationRevision == revision, draftText == text else {
                    return
                }
                validationErrorMessage = error.localizedDescription
                isValidating = false
            }
        }
    }

    func updatePartialDraft(
        _ text: String,
        changedFieldsJSON: Data,
        prepare: @escaping @MainActor @Sendable (
            WorkspaceDocumentPartialUpdateDraft
        ) async throws -> WorkspacePreparedDocumentPartialUpdate
    ) {
        draftText = text
        validationRevision &+= 1
        let revision = validationRevision
        validationTask?.cancel()
        preparedChange = nil
        validationErrorMessage = nil
        isValidating = false

        guard hasChanges, editingState == .editing,
              let snapshot = loadedSnapshot,
              let sequenceNumber = snapshot.sequenceNumber,
              let primaryTerm = snapshot.primaryTerm
        else { return }

        isValidating = true
        validationTask = Task { @MainActor [validator] in
            do {
                let sourceJSON = try await validator.validate(text)
                try Task.checkCancellation()
                let draft = WorkspaceDocumentPartialUpdateDraft(
                    reference: snapshot.reference,
                    sequenceNumber: sequenceNumber,
                    primaryTerm: primaryTerm,
                    sourceJSON: sourceJSON,
                    changedFieldsJSON: changedFieldsJSON
                )
                let update = try await prepare(draft)
                try Task.checkCancellation()
                guard validationRevision == revision,
                      draftText == text,
                      editingState == .editing
                else { return }
                preparedChange = .partialUpdate(update)
                isValidating = false
            } catch is CancellationError {
                return
            } catch {
                guard validationRevision == revision, draftText == text else {
                    return
                }
                validationErrorMessage = error.localizedDescription
                isValidating = false
            }
        }
    }

    func beginDraftTransformation() {
        validationRevision &+= 1
        validationTask?.cancel()
        validationTask = nil
        preparedChange = nil
        validationErrorMessage = nil
        isValidating = true
    }

    func stageCellChanges(
        snapshot: WorkspaceDocumentSnapshot,
        edits: [String: WorkspaceDatabaseDataCell],
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentPartialUpdateDraft) async throws
            -> WorkspacePreparedDocumentPartialUpdate
    ) throws {
        guard !isCommitting, editingState == .viewing,
              !hasChanges || cellChanges.hasChanges
        else { throw WorkspaceDocumentEditingError.unavailable }
        try cellChanges.stage(snapshot: snapshot, edits: edits, prepare: prepare)
    }

    func commitPreparedCellChanges(
        updates: [WorkspacePreparedDocumentPartialUpdate],
        using commit: @MainActor (WorkspacePreparedDocumentPartialUpdate) async throws
            -> WorkspaceDocumentReplacementResult
    ) async throws {
        guard isCommitting else { throw WorkspaceDocumentEditingError.unavailable }
        defer { isCommitting = false }
        try await cellChanges.commit(updates: updates, using: commit)
        discardChanges()
        state = .empty
    }

    func commitPreparedCreations(
        rows: [WorkspacePreparedDocumentCreationRow],
        using commit: @MainActor (WorkspacePreparedDocumentCreation) async throws -> WorkspaceDocumentCreationResult
    ) async throws -> [WorkspaceDocumentCreationResult] {
        guard isCommitting else { throw WorkspaceDocumentEditingError.unavailable }
        defer { isCommitting = false }
        let results = try await creations.commit(rows: rows, using: commit)
        discardChanges()
        state = .empty
        return results
    }

    func addCreation(
        rowID: UUID, targetName: String, targetKind: WorkspaceDocumentCreationTargetKind,
        sourceJSON: Data = Data("{}".utf8), routing: String? = nil,
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentCreationDraft) async throws -> WorkspacePreparedDocumentCreation
    ) throws {
        guard !isCommitting, editingState == .viewing, !hasChanges || creations.hasChanges else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        try creations.add(rowID: rowID, targetName: targetName, targetKind: targetKind,
            sourceJSON: sourceJSON, routing: routing, prepare: prepare)
    }

    func cancelDraftValidation() {
        validationTask?.cancel()
        validationTask = nil
        validationRevision &+= 1
        preparedChange = nil
        isValidating = false
    }

    func stageDeletion(
        _ deletion: WorkspacePreparedDocumentDeletion,
        snapshot: WorkspaceDocumentSnapshot
    ) throws {
        guard (!hasChanges || isPendingDeletion), !isCommitting else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        guard let sequenceNumber = snapshot.sequenceNumber,
              let primaryTerm = snapshot.primaryTerm,
              deletion.draft.reference == snapshot.reference,
              deletion.draft.sequenceNumber == sequenceNumber,
              deletion.draft.primaryTerm == primaryTerm
        else {
            throw WorkspaceDocumentEditingError.missingConcurrencyMetadata
        }
        try stageDeletions([deletion])
        state = .loaded(snapshot)
    }

    func stageDeletions(_ deletions: [WorkspacePreparedDocumentDeletion]) throws {
        guard (!hasChanges || isPendingDeletion), !isCommitting else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        var combined = preparedDeletions
        var references = Set(combined.map { $0.draft.reference })
        for deletion in deletions where references.insert(deletion.draft.reference).inserted {
            combined.append(deletion)
        }
        guard !combined.isEmpty else { return }
        let wasConflicted = editingState == .deletionConflicted
        validationTask?.cancel()
        validationTask = nil
        validationRevision &+= 1
        draftText = ""
        validationErrorMessage = nil
        isValidating = false
        editingState = wasConflicted ? .deletionConflicted : .viewing
        setDeletions(combined)
    }

    func undoDeletions(references: Set<WorkspaceDocumentReference>) {
        guard isPendingDeletion, !isCommitting else { return }
        setDeletions(preparedDeletions.filter { !references.contains($0.draft.reference) })
        if !hasChanges { discardChanges() }
    }

    private func setDeletions(_ deletions: [WorkspacePreparedDocumentDeletion]) {
        guard let first = deletions.first else {
            preparedChange = nil
            return
        }
        preparedChange = deletions.count == 1
            ? .deletion(first)
            : .deletions(first: first, rest: Array(deletions.dropFirst()))
    }

    func commitPreparedDeletions(
        using commit: @MainActor (WorkspacePreparedDocumentDeletion) async throws
            -> WorkspaceDocumentDeletionResult
    ) async throws {
        guard isCommitting, isPendingDeletion else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        let deletions = preparedDeletions
        var succeeded = 0
        do {
            for deletion in deletions {
                try Task.checkCancellation()
                let result = try await commit(deletion)
                guard result.reference == deletion.draft.reference else {
                    throw WorkspaceDocumentEditingError.unavailable
                }
                succeeded += 1
            }
        } catch {
            // Retain only unacknowledged requests, without rebuilding the full list per response.
            setDeletions(Array(deletions.dropFirst(succeeded)))
            throw error
        }
        discardChanges()
        state = .empty
    }

    func finishDraftTransformationFailure(_ error: Error) {
        validationErrorMessage = error.localizedDescription
        isValidating = false
    }

    func beginCommit() -> WorkspacePreparedDocumentChange? {
        guard canCommit, let preparedChange else { return nil }
        validationTask?.cancel()
        isCommitting = true
        if cellChanges.hasChanges { cellChanges.beginCommit() }
        if creations.hasChanges { creations.beginCommit() }
        return preparedChange
    }

    func waitForValidation() async {
        await validationTask?.value
        await cellChanges.waitForValidation()
        await creations.waitForValidation()
    }

    func finishCommit(_ result: WorkspaceDocumentReplacementResult) {
        guard let snapshot = loadedSnapshot,
              let sourceJSON = preparedChange?.sourceJSON
        else {
            isCommitting = false
            return
        }
        state = .loaded(WorkspaceDocumentSnapshot(
            reference: result.reference,
            version: result.version,
            sequenceNumber: result.sequenceNumber,
            primaryTerm: result.primaryTerm,
            score: snapshot.score,
            sourceJSON: sourceJSON,
            isTruncated: false
        ))
        isCommitting = false
        discardChanges()
    }

    func finishCreationCommit(_ result: WorkspaceDocumentCreationResult) {
        guard preparedCreation != nil else {
            isCommitting = false
            return
        }
        discardChanges()
        state = .empty
    }

    func finishDeletionCommit(_ result: WorkspaceDocumentDeletionResult) {
        guard preparedDeletion?.draft.reference == result.reference else {
            isCommitting = false
            return
        }
        discardChanges()
        state = .empty
    }

    func finishCommitFailure(_ error: Error) {
        isCommitting = false
        if error is CancellationError {
            isCommitOutcomeUncertain = true
            return
        }
        guard let editingError = error as? WorkspaceDocumentEditingError,
              editingError == .conflict
                || editingError == .documentNotFound
                || editingError == .documentAlreadyExists
        else { return }
        if isCreating {
            validationErrorMessage = editingError.localizedDescription
            preparedChange = nil
            return
        }
        if isPendingDeletion {
            editingState = .deletionConflicted
        } else {
            editingState = .conflicted
            preparedChange = nil
        }
    }

    func discardChanges() {
        creations.discard()
        cellChanges.discard()
        validationTask?.cancel()
        validationTask = nil
        validationRevision &+= 1
        draftText = ""
        creationDocumentID = ""
        creationRouting = ""
        creationTargetName = nil
        creationTargetKind = nil
        validationErrorMessage = nil
        preparedChange = nil
        isCommitting = false
        isCommitOutcomeUncertain = false
        isValidating = false
        editingState = .viewing
    }

    private nonisolated static func optionalIdentity(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : value
    }
}
