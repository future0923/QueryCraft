import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchDocumentCreationsTests {
    @Test func independentRowsKeepIDsRoutingAndJSONTypes() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let ids = [UUID(), UUID(), UUID()]
        for id in ids { try add(model, id) }
        edit(model, ids[0], id: "manual-1", text: #"{"count":21,"enabled":false,"text":"21"}"#)
        edit(model, ids[1], id: "manual-2", routing: "tenant-a", text: #"{"tags":["a","b"],"nullable":null}"#)
        edit(model, ids[2], text: #"{"name":"auto"}"#)
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        #expect(rows.map(\.rowID) == ids)
        #expect(rows.map { $0.creation.draft.id } == ["manual-1", "manual-2", nil])
        #expect(rows[1].creation.draft.routing == "tenant-a")
        #expect(rows[0].creation.draft.sourceJSON == Data(#"{"count":21,"enabled":false,"text":"21"}"#.utf8))
        #expect(model.preparedChange?.requests == rows.map { $0.creation.request })
        #expect(model.canCommit)
        #expect(!model.blocksDocumentSelectionChanges)
    }

    @Test func gridEditsAcrossRowsDoNotCancelOrOverwriteEachOther() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = UUID(), second = UUID()
        try add(model, first); try add(model, second)
        for (id, count) in [(first, "21"), (second, "22"), (first, "23")] {
            model.creations.updateGrid(row: row(id, count: count), prepare: Self.prepare)
        }
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        let firstJSON = try #require(JSONSerialization.jsonObject(with: rows[0].creation.draft.sourceJSON) as? [String: Any])
        let secondJSON = try #require(JSONSerialization.jsonObject(with: rows[1].creation.draft.sourceJSON) as? [String: Any])
        #expect(firstJSON["count"] as? Int == 23)
        #expect(secondJSON["count"] as? Int == 22)
        #expect(rows[0].creation.draft.id == "manual-23")
        #expect(rows[1].creation.draft.id == "manual-22")
    }

    @Test func removingOneDraftKeepsOtherRowsAndCancelsLateProjection() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = UUID(), second = UUID()
        try add(model, first); try add(model, second)
        edit(model, first, id: "first", text: #"{"count":1}"#)
        edit(model, second, id: "second", text: #"{"count":2}"#)
        model.creations.remove(rowIDs: [first])
        await model.waitForValidation()
        #expect(model.creations.order == [second])
        #expect(model.creations.projections[first] == nil)
        #expect(model.creations.preparedRows?.first?.creation.draft.id == "second")
        model.discardChanges()
        #expect(!model.hasChanges)
        #expect(model.creations.projections.isEmpty)
    }

    @Test func exactPreviewOrderIsCommittedAndAutoIDIsAcknowledgedOnce() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        for _ in 0..<3 { try add(model, UUID()) }
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        let preview = try #require(model.preparedChange?.requests)
        _ = try #require(model.beginCommit())
        var requests: [WorkspaceRequest] = []
        let results = try await model.commitPreparedCreations(rows: rows) { creation in
            requests.append(creation.request)
            #expect(throws: WorkspaceDocumentEditingError.unavailable) { try add(model, UUID()) }
            return result(creation, autoID: "generated-\(requests.count)")
        }
        #expect(requests == preview)
        #expect(results.map(\.reference.id) == ["generated-1", "generated-2", "generated-3"])
        #expect(!model.hasChanges)
        #expect(!model.isCommitting)
    }

    @Test func duplicateIDStopsBatchAndCanBeCorrectedWithoutResendingSuccess() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let ids = [UUID(), UUID(), UUID()]
        for id in ids { try add(model, id) }
        for (index, id) in ids.enumerated() { edit(model, id, id: "doc-\(index)") }
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        var attempts: [String?] = []
        await #expect(throws: WorkspaceDocumentEditingError.documentAlreadyExists) {
            try await model.commitPreparedCreations(rows: rows) { creation in
                attempts.append(creation.draft.id)
                if attempts.count == 2 { throw WorkspaceDocumentEditingError.documentAlreadyExists }
                return result(creation)
            }
        }
        #expect(attempts == ["doc-0", "doc-1"])
        #expect(model.creations.order == Array(ids.dropFirst()))
        #expect(!model.canCommit)
        #expect(model.creations.canCorrectDuplicateID)
        edit(model, ids[1], id: "corrected")
        await model.waitForValidation()
        #expect(model.canCommit)
        let remaining = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        _ = try await model.commitPreparedCreations(rows: remaining) { creation in
            attempts.append(creation.draft.id)
            return result(creation)
        }
        #expect(attempts == ["doc-0", "doc-1", "corrected", "doc-2"])
        #expect(!model.hasChanges)
    }

    @Test func removingDuplicateIDFailureUnlocksOnlyRemainingDrafts() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let ids = [UUID(), UUID()]
        for id in ids { try add(model, id) }
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        await #expect(throws: WorkspaceDocumentEditingError.documentAlreadyExists) {
            try await model.commitPreparedCreations(rows: rows) { _ in
                throw WorkspaceDocumentEditingError.documentAlreadyExists
            }
        }
        model.creations.remove(rowIDs: [ids[0]])
        #expect(model.creations.order == [ids[1]])
        #expect(model.canCommit)
        #expect(!model.creations.isBlocked)
    }

    @Test func boundedBatchPreservesAllPreparedRows() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let ids = (0..<500).map { _ in UUID() }
        for id in ids { try add(model, id) }
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try add(model, UUID()) }
        await model.waitForValidation()
        #expect(model.creations.preparedRows?.map(\.rowID) == ids)
        #expect(model.canCommit)
        model.discardChanges()
        #expect(!model.hasChanges)
    }

    @Test func finalAcknowledgedResponseWinsOverCancellation() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try add(model, UUID())
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        let task = Task { @MainActor in
            try await model.commitPreparedCreations(rows: rows) { creation in
                withUnsafeCurrentTask { $0?.cancel() }
                return result(creation, autoID: "confirmed-final")
            }
        }
        let results = try await task.value
        #expect(results.map(\.reference.id) == ["confirmed-final"])
        #expect(!model.hasChanges)
        #expect(!model.isCommitting)
    }

    @Test func uncertainAutoIDOutcomeCannotBeRetriedOrUnlockedByEditing() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let id = UUID()
        try add(model, id)
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        await #expect(throws: URLError.self) {
            try await model.commitPreparedCreations(rows: rows) { _ in throw URLError(.timedOut) }
        }
        #expect(model.creations.preparedRows == rows)
        #expect(!model.creations.canCorrectDuplicateID)
        edit(model, id, id: "attempt-to-unlock")
        #expect(!model.canCommit)
        #expect(model.creations.preparedRows == rows)
        model.discardChanges()
        #expect(!model.hasChanges)
    }

    @Test func cancellationAfterAcknowledgementRetainsOnlyUnattemptedRows() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let ids = [UUID(), UUID()]
        for id in ids { try add(model, id) }
        await model.waitForValidation()
        let rows = try #require(model.creations.preparedRows)
        _ = try #require(model.beginCommit())
        let task = Task { @MainActor in
            try await model.commitPreparedCreations(rows: rows) { creation in
                withUnsafeCurrentTask { $0?.cancel() }
                return result(creation, autoID: "confirmed")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.creations.order == [ids[1]])
        #expect(!model.canCommit)
        #expect(!model.isCommitting)
    }

    @Test func invalidJSONDoesNotLoseOtherDraftsAndCanBeCorrected() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = UUID(), second = UUID()
        try add(model, first); try add(model, second)
        edit(model, first, text: "[")
        edit(model, second, text: #"{"count":2}"#)
        await model.waitForValidation()
        #expect(model.creations.entries[first]?.draftText == "[")
        #expect(model.validationErrorMessage != nil)
        #expect(!model.canCommit)
        #expect(model.creations.entries[second]?.preparedCreation != nil)
        edit(model, first, text: "{}")
        await model.waitForValidation()
        #expect(model.canCommit)
    }

    @Test func creationCannotMixWithAnExistingFullJSONDraft() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try model.beginCreating(targetName: "logs", targetKind: .index, prepare: Self.prepare)
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try add(model, UUID()) }
        model.discardChanges()
        try add(model, UUID())
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try model.beginCreating(targetName: "logs", targetKind: .index, prepare: Self.prepare)
        }
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try model.stageDeletions([.init(draft: .init(reference: .init(index: "logs", id: "1"), sequenceNumber: 1, primaryTerm: 1),
                request: .init(method: .delete, path: "/logs/_doc/1"))])
        }
        model.discardChanges()
    }

    @Test func stalePreparationCannotResurrectDiscardedRows() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let started = CreationSignal(), release = CreationSignal(), finished = CreationSignal()
        let id = UUID()
        try model.addCreation(rowID: id, targetName: "logs", targetKind: .index) { draft in
            await started.signal()
            await release.wait()
            await finished.signal()
            return Self.prepare(draft)
        }
        model.creations.project(rowID: id, fieldNames: ["count"])
        await started.wait()
        model.discardChanges()
        await release.signal()
        await finished.wait()
        #expect(!model.hasChanges)
        #expect(model.creations.projections.isEmpty)
    }

    private func add(_ model: WorkspaceElasticsearchDocumentInspectorModel, _ id: UUID) throws {
        try model.addCreation(rowID: id, targetName: "logs-write", targetKind: .alias, prepare: Self.prepare)
    }

    private func edit(_ model: WorkspaceElasticsearchDocumentInspectorModel, _ rowID: UUID,
                      id: String = "", routing: String = "", text: String = "{}") {
        model.creations.updateInspector(rowID: rowID, documentID: id, routing: routing, text: text,
            fieldNames: ["count", "enabled", "text", "tags", "nullable", "name"], prepare: Self.prepare)
    }

    private static func prepare(_ draft: WorkspaceDocumentCreationDraft) -> WorkspacePreparedDocumentCreation {
        .init(draft: draft, request: .init(method: draft.id == nil ? .post : .put,
            path: "/\(draft.targetName)/" + (draft.id.map { "_create/\($0)" } ?? "_doc"), body: draft.sourceJSON))
    }

    private func result(_ creation: WorkspacePreparedDocumentCreation, autoID: String = "auto") -> WorkspaceDocumentCreationResult {
        .init(reference: .init(index: "logs-000001", id: creation.draft.id ?? autoID, routing: creation.draft.routing),
            version: 1, sequenceNumber: 1, primaryTerm: 1)
    }

    private func row(_ id: UUID, count: String) -> WorkspaceDatabaseDataRowInsertDraftRow {
        .init(id: id, drafts: ["_id": .init(mode: .value, text: "manual-\(count)"),
            "count": .init(mode: .value, text: count)], editedColumnNames: ["_id", "count"])
    }
}

private actor CreationSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
