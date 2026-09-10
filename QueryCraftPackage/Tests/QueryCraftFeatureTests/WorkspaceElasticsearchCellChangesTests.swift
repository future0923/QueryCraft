import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchCellChangesTests {
    @Test func multipleDocumentsMergeFieldsAndKeepOriginalVersions() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = snapshot("same", routing: "a")
        let second = snapshot("same", routing: "b")
        try stage(model, first, ["count": .text("21")])
        try stage(model, second, ["name": .text("second")])
        #expect(model.hasChanges)
        #expect(!model.canCommit)
        #expect(!model.blocksDocumentSelectionChanges)
        await model.load(reference: second.reference) { _ in second }
        #expect(model.loadedSnapshot == second)
        #expect(model.cellChanges.order == [first.reference, second.reference])
        #expect(!model.canBeginEditing)
        let newer = snapshot("same", routing: "a", sequence: 999)
        try stage(model, newer, ["count": .text("22"), "enabled": .text("false")])
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        #expect(updates.count == 2)
        #expect(updates[0].draft.sequenceNumber == first.sequenceNumber)
        #expect(updates[0].draft.reference == first.reference)
        #expect(updates[1].draft.reference == second.reference)
        #expect(updates[0].draft.changedFieldsJSON == Data(#"{"count":22,"enabled":false}"#.utf8))
        #expect(updates[1].draft.changedFieldsJSON == Data(#"{"name":"second"}"#.utf8))
        #expect(model.preparedChange?.requests == updates.map(\.request))
        #expect(model.canCommit)
    }

    @Test func returningOneDocumentToOriginalDoesNotDiscardOthers() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = snapshot("1"), second = snapshot("2")
        try stage(model, first, ["count": .text("21")])
        try stage(model, second, ["name": .text("second")])
        await model.waitForValidation()
        try stage(model, first, ["count": .text("1"), "nullText": .text(#""null""#)])
        await model.waitForValidation()
        #expect(model.cellChanges.order == [second.reference])
        #expect(model.cellChanges.retainedFields == [second.reference: ["name"]])
        #expect(model.canCommit)
        try stage(model, second, [:])
        #expect(!model.hasChanges)
    }

    @Test func reopeningDraftPreservesJSONTypesAndExplicitNull() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let original = snapshot("1")
        try stage(model, original, [
            "nullText": .null, "count": .text("21"), "enabled": .text("false"),
            "numericText": .text(#""21""#), "booleanText": .text(#""false""#),
            "tags": .text(#"["a","b"]"#), "profile": .text(#"{"city":"Shenyang"}"#)
        ])
        let reopened = try await model.cellChanges.initialValue(snapshot: original, fieldName: "numericText")
        #expect(reopened.text == #""21""#)
        await model.waitForValidation()
        let prepared = try #require(model.cellChanges.preparedUpdates?.first)
        let fields = try #require(JSONSerialization.jsonObject(with: prepared.draft.changedFieldsJSON) as? [String: Any])
        #expect(fields["nullText"] is NSNull)
        #expect(fields["numericText"] as? String == "21")
        #expect(fields["booleanText"] as? String == "false")
        #expect(fields["count"] as? Int == 21)
        #expect(fields["enabled"] as? Bool == false)
        #expect(fields["tags"] as? [String] == ["a", "b"])
        #expect(fields["name"] == nil)
    }

    @Test func staleValidationCannotReplaceNewDraftOrAnotherDocument() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = snapshot("1"), second = snapshot("2")
        let started = CellChangeSignal(), release = CellChangeSignal(), completed = CellChangeSignal()
        try model.stageCellChanges(snapshot: first, edits: ["count": .text("20")]) { draft in
            await started.signal()
            await release.wait()
            await completed.signal()
            return Self.prepare(draft)
        }
        await started.wait()
        try stage(model, second, ["count": .text("22")])
        try stage(model, first, ["count": .text("23")])
        await model.waitForValidation()
        await release.signal()
        await completed.wait()
        #expect(model.cellChanges.preparedUpdates?.map(\.draft.changedFieldsJSON) == [
            Data(#"{"count":23}"#.utf8), Data(#"{"count":22}"#.utf8)
        ])
        #expect(model.canCommit)
    }

    @Test func discardInvalidatesInFlightValidation() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let started = CellChangeSignal(), release = CellChangeSignal(), finished = CellChangeSignal()
        try model.stageCellChanges(snapshot: snapshot("1"), edits: ["count": .text("2")]) { draft in
            await started.signal()
            await release.wait()
            await finished.signal()
            return Self.prepare(draft)
        }
        await started.wait()
        model.discardChanges()
        await release.signal()
        await finished.wait()
        #expect(!model.hasChanges)
        #expect(!model.isValidating)
        #expect(model.preparedChange == nil)
    }

    @Test func previewAndCommitUseExactlyTheSameOrderedRequests() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try stage(model, snapshot("1"), ["count": .text("11")])
        try stage(model, snapshot("2", routing: "tenant-a"), ["count": .text("12")])
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        let preview = try #require(model.preparedChange?.requests)
        _ = try #require(model.beginCommit())
        var executed: [WorkspaceRequest] = []
        try await model.commitPreparedCellChanges(updates: updates) { update in
            #expect(!model.canCommit)
            #expect(throws: WorkspaceDocumentEditingError.unavailable) {
                try stage(model, snapshot("3"), ["count": .text("3")])
            }
            executed.append(update.request)
            return result(update.draft.reference)
        }
        #expect(executed == preview)
        #expect(!model.hasChanges)
        #expect(!model.isCommitting)
    }

    @Test func failureKeepsOnlyFailedAndUnattemptedDraftsAndBlocksRetry() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        for id in ["1", "2", "3"] { try stage(model, snapshot(id), ["count": .text("21")]) }
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        _ = try #require(model.beginCommit())
        var attempted: [String] = []
        await #expect(throws: WorkspaceDocumentEditingError.conflict) {
            try await model.commitPreparedCellChanges(updates: updates) { update in
                attempted.append(update.draft.reference.id)
                if attempted.count == 2 { throw WorkspaceDocumentEditingError.conflict }
                return result(update.draft.reference)
            }
        }
        #expect(attempted == ["1", "2"])
        #expect(model.cellChanges.preparedUpdates == Array(updates.dropFirst()))
        #expect(!model.isCommitting)
        #expect(!model.canCommit)
        #expect(model.beginCommit() == nil)
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try stage(model, snapshot("4"), ["count": .text("2")])
        }
        model.discardChanges()
        #expect(!model.hasChanges)
    }

    @Test func cancelledAcknowledgedUpdateIsNotRetained() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        for id in ["1", "2"] { try stage(model, snapshot(id), ["count": .text("21")]) }
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        _ = try #require(model.beginCommit())
        let task = Task { @MainActor in
            try await model.commitPreparedCellChanges(updates: updates) { update in
                withUnsafeCurrentTask { $0?.cancel() }
                return result(update.draft.reference)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.cellChanges.preparedUpdates == [updates[1]])
        #expect(!model.canCommit)
        #expect(!model.isCommitting)
    }

    @Test func uncertainOutcomeKeepsDraftAndBlocksBlindRetry() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try stage(model, snapshot("1"), ["count": .text("21")])
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        _ = try #require(model.beginCommit())
        await #expect(throws: URLError.self) {
            try await model.commitPreparedCellChanges(updates: updates) { _ in throw URLError(.timedOut) }
        }
        #expect(model.cellChanges.preparedUpdates == updates)
        #expect(model.cellChanges.isBlocked)
        #expect(!model.canCommit)
    }

    @Test func finalAcknowledgementWinsOverConcurrentCancellation() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try stage(model, snapshot("1"), ["count": .text("21")])
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        _ = try #require(model.beginCommit())
        let task = Task { @MainActor in
            try await model.commitPreparedCellChanges(updates: updates) { update in
                withUnsafeCurrentTask { $0?.cancel() }
                return result(update.draft.reference)
            }
        }
        try await task.value
        #expect(!model.hasChanges)
        #expect(!model.isCommitting)
    }

    @Test func wrongResponseIdentityCannotAcknowledgeAnotherDraft() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try stage(model, snapshot("1", routing: "tenant-a"), ["count": .text("21")])
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        _ = try #require(model.beginCommit())
        await #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try await model.commitPreparedCellChanges(updates: updates) { _ in
                result(WorkspaceDocumentReference(index: "logs-000001", id: "1", routing: "tenant-b"))
            }
        }
        #expect(model.cellChanges.preparedUpdates == updates)
        #expect(!model.canCommit)
    }

    @Test func invalidSourceAndOversizedDraftKeepInputButCannotSubmit() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let original = snapshot("1")
        let input = String(repeating: "x", count: WorkspaceElasticsearchDocumentValidator.maximumByteCount)
        try stage(model, original, ["name": .text(input)])
        await model.waitForValidation()
        #expect(model.cellChanges.entries[original.reference]?.edits["name"] == .text(input))
        #expect(model.validationErrorMessage != nil)
        #expect(!model.canCommit)
        try stage(model, original, ["name": .text("valid")])
        await model.waitForValidation()
        #expect(model.validationErrorMessage == nil)
        #expect(model.canCommit)
        model.discardChanges()
        try stage(model, original, ["_id": .text("different")])
        await model.waitForValidation()
        #expect(!model.canCommit)
        #expect(model.validationErrorMessage != nil)
    }

    @Test func cellChangesCannotMixWithFullJSONCreationOrDeletion() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let original = snapshot("1")
        await model.load(reference: original.reference) { _ in original }
        try stage(model, original, ["count": .text("2")])
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try model.beginEditing() }
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try model.stageDeletions([WorkspacePreparedDocumentDeletion(
                draft: WorkspaceDocumentDeletionDraft(reference: original.reference, sequenceNumber: 10, primaryTerm: 2),
                request: WorkspaceRequest(method: .delete, path: "/logs/_doc/1")
            )])
        }
        model.discardChanges()
        try model.beginEditing()
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try stage(model, original, ["count": .text("2")]) }
        model.discardChanges()
        try model.beginCreating(targetName: "logs", targetKind: .index) { draft in
            WorkspacePreparedDocumentCreation(draft: draft, request: WorkspaceRequest(method: .post, path: "/logs/_doc"))
        }
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try stage(model, original, ["count": .text("2")]) }
        model.discardChanges()
    }

    @Test func originalReadsCannotReplaceANewerSelection() async {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = snapshot("1"), second = snapshot("2")
        let started = CellChangeSignal(), release = CellChangeSignal()
        let task = Task { @MainActor in
            await model.load(reference: first.reference) { _ in
                await started.signal()
                await release.wait()
                return first
            }
        }
        await started.wait()
        await model.load(reference: second.reference) { _ in second }
        await release.signal()
        await task.value
        #expect(model.loadedSnapshot == second)
    }

    @Test func hundredLargeDocumentsProduceBoundedFieldOnlyRequests() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let source = Data((#"{"count":1,"unchanged":""# + String(repeating: "x", count: 100_000) + #""}"#).utf8)
        for index in 0..<100 {
            let document = WorkspaceDocumentSnapshot(
                reference: WorkspaceDocumentReference(index: "logs-000001", id: String(index)),
                version: 1, sequenceNumber: Int64(index), primaryTerm: 2, score: nil,
                sourceJSON: source, isTruncated: false
            )
            try stage(model, document, ["count": .text("21")])
        }
        #expect(model.cellChanges.order.count == 100)
        await model.waitForValidation()
        let updates = try #require(model.cellChanges.preparedUpdates)
        #expect(updates.count == 100)
        #expect(updates.allSatisfy { $0.request.body?.count ?? .max < 40 })
        _ = try #require(model.beginCommit())
        var identities: [String] = []
        try await model.commitPreparedCellChanges(updates: updates) { update in
            identities.append(update.draft.reference.id)
            return result(update.draft.reference)
        }
        #expect(identities == (0..<100).map(String.init))
        #expect(!model.hasChanges)
    }

    private func stage(_ model: WorkspaceElasticsearchDocumentInspectorModel,
                       _ snapshot: WorkspaceDocumentSnapshot,
                       _ edits: [String: WorkspaceDatabaseDataCell]) throws {
        try model.stageCellChanges(snapshot: snapshot, edits: edits, prepare: Self.prepare)
    }

    private static func prepare(_ draft: WorkspaceDocumentPartialUpdateDraft) -> WorkspacePreparedDocumentPartialUpdate {
        var body = Data(#"{"doc":"#.utf8)
        body.append(draft.changedFieldsJSON)
        body.append(Data("}".utf8))
        return WorkspacePreparedDocumentPartialUpdate(draft: draft, request: WorkspaceRequest(
            method: .post, path: "/\(draft.reference.index)/_update/\(draft.reference.id)?if_seq_no=\(draft.sequenceNumber)&if_primary_term=\(draft.primaryTerm)", body: body
        ))
    }

    private func snapshot(_ id: String, routing: String? = nil, sequence: Int64 = 10) -> WorkspaceDocumentSnapshot {
        WorkspaceDocumentSnapshot(reference: WorkspaceDocumentReference(index: "logs-000001", id: id, routing: routing),
            version: 1, sequenceNumber: sequence, primaryTerm: 2, score: nil,
            sourceJSON: Data(#"{"count":1,"enabled":true,"name":"original","nullText":"null"}"#.utf8), isTruncated: false)
    }

    private func result(_ reference: WorkspaceDocumentReference) -> WorkspaceDocumentReplacementResult {
        WorkspaceDocumentReplacementResult(reference: reference, version: 2, sequenceNumber: 11, primaryTerm: 2)
    }
}

private actor CellChangeSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
