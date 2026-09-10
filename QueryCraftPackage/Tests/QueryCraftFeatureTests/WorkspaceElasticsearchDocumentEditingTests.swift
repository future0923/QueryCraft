import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite("Elasticsearch document editing model")
struct WorkspaceElasticsearchDocumentEditingTests {
    @Test("Batch deletion deduplicates identities, preserves routing, and selectively undoes")
    func batchDeletionStagesAndUndoes() throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let first = deletion(id: "1", routing: "a")
        let routed = deletion(id: "1", routing: "b")
        let last = deletion(id: "2")
        try model.stageDeletions([first, routed])
        try model.stageDeletions([first, last])
        #expect(model.preparedDeletions == [first, routed, last])
        #expect(model.preparedChange?.requests == [first.request, routed.request, last.request])
        #expect(!model.blocksDocumentSelectionChanges)
        #expect(!model.canBeginEditing)

        model.undoDeletions(references: [routed.draft.reference])
        #expect(model.preparedDeletions == [first, last])
        model.discardChanges()
        #expect(model.preparedDeletions.isEmpty)
        #expect(!model.hasChanges)
    }

    @Test("Batch deletion retains failures and unattempted requests after partial success")
    func batchDeletionPartialFailure() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let requests = [deletion(id: "1"), deletion(id: "2"), deletion(id: "3")]
        try model.stageDeletions(requests)
        _ = try #require(model.beginCommit())
        var attempted: [WorkspacePreparedDocumentDeletion] = []
        await #expect(throws: WorkspaceDocumentEditingError.conflict) {
            try await model.commitPreparedDeletions { deletion in
                attempted.append(deletion)
                if deletion == requests[1] { throw WorkspaceDocumentEditingError.conflict }
                return WorkspaceDocumentDeletionResult(reference: deletion.draft.reference)
            }
        }
        #expect(attempted == Array(requests.prefix(2)))
        #expect(model.preparedDeletions == Array(requests.dropFirst()))
        model.finishCommitFailure(WorkspaceDocumentEditingError.conflict)
        #expect(!model.canCommit)
        try model.stageDeletions([deletion(id: "4")])
        #expect(!model.canCommit)
    }

    @Test("Batch deletion executes exactly the previewed requests and clears successes")
    func batchDeletionCommitsPreview() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let requests = [deletion(id: "1"), deletion(id: "2", routing: "tenant-a")]
        try model.stageDeletions(requests)
        let preview = try #require(model.preparedChange?.requests)
        _ = try #require(model.beginCommit())
        var executed: [WorkspaceRequest] = []
        try await model.commitPreparedDeletions { deletion in
            executed.append(deletion.request)
            model.undoDeletions(references: [deletion.draft.reference])
            #expect(model.preparedDeletions == requests)
            return WorkspaceDocumentDeletionResult(reference: deletion.draft.reference)
        }
        #expect(executed == preview)
        #expect(!model.hasChanges)
        #expect(!model.isCommitting)
    }

    @Test("Cancellation after a confirmed deletion retains only the unattempted remainder")
    func batchDeletionCancellation() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let requests = [deletion(id: "1"), deletion(id: "2")]
        try model.stageDeletions(requests)
        _ = try #require(model.beginCommit())
        var calls = 0
        let task = Task { @MainActor in
            try await model.commitPreparedDeletions { deletion in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return WorkspaceDocumentDeletionResult(reference: deletion.draft.reference)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 1)
        #expect(model.preparedDeletions == [requests[1]])
    }

    @Test("Deletion cannot replace an existing creation draft")
    func batchDeletionRejectsEditingDraft() throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try model.beginCreating(targetName: "logs", targetKind: .index) { draft in
            WorkspacePreparedDocumentCreation(
                draft: draft,
                request: WorkspaceRequest(method: .post, path: "/logs/_doc", body: draft.sourceJSON)
            )
        }
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try model.stageDeletions([deletion(id: "1")])
        }
        #expect(model.isCreating)
        model.discardChanges()
    }

    private func deletion(id: String, routing: String? = nil) -> WorkspacePreparedDocumentDeletion {
        WorkspacePreparedDocumentDeletion(
            draft: WorkspaceDocumentDeletionDraft(
                reference: WorkspaceDocumentReference(index: "logs-000001", id: id, routing: routing),
                sequenceNumber: 10,
                primaryTerm: 2
            ),
            request: WorkspaceRequest(
                method: .delete,
                path: "/logs-000001/_doc/\(id)?if_seq_no=10&if_primary_term=2&refresh=wait_for"
                    + (routing.map { "&routing=\($0)" } ?? "")
            )
        )
    }

    @Test("Stages and updates a new document draft")
    func newDocumentDraft() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()

        try model.beginCreating(
            targetName: "logs-write",
            targetKind: .alias
        ) { draft in
            let path = draft.id.map { "/logs-write/_create/\($0)" }
                ?? "/logs-write/_doc"
            return WorkspacePreparedDocumentCreation(
                draft: draft,
                request: WorkspaceRequest(
                    method: draft.id == nil ? .post : .put,
                    path: path,
                    body: draft.sourceJSON
                )
            )
        }
        await model.waitForValidation()

        #expect(model.isCreating)
        #expect(model.hasChanges)
        #expect(model.blocksDocumentSelectionChanges)
        #expect(model.preparedCreation?.draft.id == nil)
        #expect(model.canCommit)

        model.updateCreationDraft(
            documentID: "manual-1",
            routing: "tenant-a",
            text: #"{"name":"Ada"}"#
        ) { draft in
            WorkspacePreparedDocumentCreation(
                draft: draft,
                request: WorkspaceRequest(
                    method: .put,
                    path: "/logs-write/_create/manual-1",
                    body: draft.sourceJSON
                )
            )
        }
        await model.waitForValidation()

        #expect(model.preparedCreation?.draft.id == "manual-1")
        #expect(model.preparedCreation?.draft.routing == "tenant-a")
        #expect(
            model.preparedCreation?.draft.sourceJSON
                == Data(#"{"name":"Ada"}"#.utf8)
        )
        guard case .creation = try #require(model.beginCommit()) else {
            Issue.record("Expected a staged document creation")
            return
        }
        model.finishCommitFailure(
            WorkspaceDocumentEditingError.documentAlreadyExists
        )
        #expect(model.isCreating)
        #expect(model.draftText == #"{"name":"Ada"}"#)
        #expect(model.preparedCreation == nil)
        #expect(!model.canCommit)

        model.discardChanges()
        #expect(!model.hasChanges)
        #expect(!model.isCreating)
    }

    @Test("Starts a duplicated document with source and routing but no ID")
    func duplicatedDocumentDraft() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let source = Data(
            #"{"name":"Ada","nested":{"enabled":true},"dynamic":21}"#.utf8
        )

        try model.beginCreating(
            targetName: "logs-write",
            targetKind: .alias,
            sourceJSON: source,
            routing: "tenant-a"
        ) { draft in
            WorkspacePreparedDocumentCreation(
                draft: draft,
                request: WorkspaceRequest(
                    method: .post,
                    path: "/logs-write/_doc",
                    body: draft.sourceJSON
                )
            )
        }
        await model.waitForValidation()

        #expect(model.creationDocumentID.isEmpty)
        #expect(model.creationRouting == "tenant-a")
        #expect(model.draftText == String(data: source, encoding: .utf8))
        #expect(model.preparedCreation?.draft.id == nil)
        #expect(model.preparedCreation?.draft.routing == "tenant-a")
        #expect(model.preparedCreation?.draft.sourceJSON == source)
        #expect(model.canCommit)
    }

    @Test("Formats top-level values for inline grid editing")
    func inlineGridInitialValues() async throws {
        let editor = WorkspaceElasticsearchDocumentCellEditor()
        let source = Data(
            #"{"name":"袁立伟zq","tags":["a","b"],"nullable":null,"nullText":"null","booleanText":"true","numberText":"20"}"#.utf8
        )

        let name = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "name"
        )
        #expect(name.text == "袁立伟zq")
        #expect(name.mutation == .value("袁立伟zq"))

        let tags = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "tags"
        )
        #expect(tags.text == #"["a","b"]"#)

        let nullable = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "nullable"
        )
        #expect(nullable.text.isEmpty)
        #expect(nullable.mutation == .null)

        let nullText = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "nullText"
        )
        #expect(nullText.text == #""null""#)
        #expect(nullText.mutation == .value(#""null""#))

        let booleanText = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "booleanText"
        )
        #expect(booleanText.text == #""true""#)

        let numberText = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "numberText"
        )
        #expect(numberText.text == #""20""#)

        let missing = try await editor.initialValue(
            sourceJSON: source,
            fieldName: "missing"
        )
        #expect(missing.text.isEmpty)
        #expect(missing.mutation == .null)
    }

    @Test("Builds visible creation cells from a JSON document")
    func creationGridDrafts() async throws {
        let editor = WorkspaceElasticsearchDocumentCellEditor()
        let drafts = try await editor.creationDrafts(
            sourceJSON: Data(
                #"{"name":"false","enabled":false,"count":21,"profile":{"city":"沈阳"},"nullable":null,"extra":"preserved"}"#.utf8
            ),
            fieldNames: [
                "name", "enabled", "count", "profile", "nullable", "missing",
            ]
        )

        #expect(drafts["name"]?.text == #""false""#)
        #expect(drafts["enabled"]?.text == "false")
        #expect(drafts["count"]?.text == "21")
        #expect(drafts["profile"]?.text == #"{"city":"沈阳"}"#)
        #expect(drafts["nullable"]?.mode == .null)
        #expect(drafts["missing"] == nil)
        #expect(drafts["extra"] == nil)
    }

    @Test("Distinguishes JSON null from a null string in inline input")
    func inlineGridNullInput() {
        #expect(
            WorkspaceElasticsearchDocumentCellEditor.cellValue(forInput: "null")
                == .null
        )
        #expect(
            WorkspaceElasticsearchDocumentCellEditor.cellValue(
                forInput: "  null\n"
            ) == .null
        )
        #expect(
            WorkspaceElasticsearchDocumentCellEditor.cellValue(
                forInput: #""null""#
            ) == .text(#""null""#)
        )
        #expect(
            WorkspaceElasticsearchDocumentCellEditor.cellValue(forInput: "")
                == .text("")
        )
    }

    @Test("Keeps Elasticsearch identity metadata read-only in the grid")
    func inlineGridReadOnlyMetadata() {
        for fieldName in ["_id", "_index", "_score", "_routing"] {
            #expect(
                !WorkspaceElasticsearchDocumentCellEditor.canEdit(
                    fieldName: fieldName
                )
            )
        }
        #expect(
            WorkspaceElasticsearchDocumentCellEditor.canEdit(
                fieldName: "areaBOList"
            )
        )
    }

    @Test("Rebuilds a document from typed inline values")
    func inlineGridReplacesTopLevelFields() async throws {
        let editor = WorkspaceElasticsearchDocumentCellEditor()
        let source = Data(
            #"{"name":"old","count":1,"enabled":false,"untouched":"keep"}"#.utf8
        )
        let replacement = try await editor.replacingFields(
            in: source,
            edits: [
                "name": .text("new name"),
                "count": .text("622887501937246211"),
                "enabled": .text("true"),
                "tags": .text(#"["a","b"]"#),
                "profile": .text(#"{"city":"长春"}"#),
                "nullable": .null,
            ]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: replacement) as? [String: Any]
        )

        #expect(object["name"] as? String == "new name")
        #expect((object["count"] as? NSNumber)?.int64Value == 622887501937246211)
        #expect((object["enabled"] as? NSNumber)?.boolValue == true)
        #expect(object["tags"] as? [String] == ["a", "b"])
        #expect((object["profile"] as? [String: String])?["city"] == "长春")
        #expect(object["nullable"] is NSNull)
        #expect(object["untouched"] as? String == "keep")

        let changedFields = try await editor.changedFieldsJSON(edits: [
            "name": .text("new name"),
            "nullable": .null,
            "nullLiteral": .text("null"),
            "nullText": .text(#""null""#),
        ])
        let changedObject = try #require(
            JSONSerialization.jsonObject(with: changedFields) as? [String: Any]
        )
        #expect(changedObject.count == 4)
        #expect(changedObject["name"] as? String == "new name")
        #expect(changedObject["nullable"] is NSNull)
        #expect(changedObject["nullLiteral"] is NSNull)
        #expect(changedObject["nullText"] as? String == "null")
        #expect(changedObject["untouched"] == nil)
    }

    @Test("Prepares a partial update for inline grid changes")
    func inlineGridPartialUpdateDraft() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let reference = WorkspaceDocumentReference(index: "logs", id: "1")
        await model.load(reference: reference) { reference in
            WorkspaceDocumentSnapshot(
                reference: reference,
                version: 4,
                sequenceNumber: 10,
                primaryTerm: 2,
                score: 1,
                sourceJSON: Data(#"{"name":"old","untouched":true}"#.utf8),
                isTruncated: false
            )
        }
        try model.beginEditing()
        let source = #"{"name":"new","untouched":true}"#
        let changedFields = Data(#"{"name":"new"}"#.utf8)

        model.updatePartialDraft(
            source,
            changedFieldsJSON: changedFields
        ) { draft in
            WorkspacePreparedDocumentPartialUpdate(
                draft: draft,
                request: WorkspaceRequest(
                    method: .post,
                    path: "/logs/_update/1",
                    body: Data(#"{"doc":{"name":"new"}}"#.utf8)
                )
            )
        }
        await model.waitForValidation()

        #expect(model.preparedReplacement == nil)
        #expect(
            model.preparedPartialUpdate?.draft.changedFieldsJSON
                == changedFields
        )
        #expect(model.preparedChange?.request.method == .post)
        guard case .partialUpdate = try #require(model.beginCommit()) else {
            Issue.record("Expected an inline-grid partial update")
            return
        }
    }

    @Test("Validates object JSON without re-encoding the source")
    func validationPreservesSource() async throws {
        let validator = WorkspaceElasticsearchDocumentValidator()
        let text = #"{"large":9007199254740993,"escaped":"a\\/b"}"#
        let data = try await validator.validate(text)
        #expect(data == Data(text.utf8))

        await #expect(throws: WorkspaceDocumentEditingError.invalidSource) {
            _ = try await validator.validate("[1, 2]")
        }
        await #expect(throws: WorkspaceDocumentEditingError.invalidSource) {
            _ = try await validator.validate("{broken")
        }
    }

    @Test("Keeps a dirty draft through validation, conflict, and uncertain cancellation", arguments: [false, true])
    func dirtyDraftAndConflict(cancelled: Bool) async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let reference = WorkspaceDocumentReference(index: "logs", id: "1")
        await model.load(reference: reference) { reference in
            WorkspaceDocumentSnapshot(
                reference: reference,
                version: 4,
                sequenceNumber: 10,
                primaryTerm: 2,
                score: 1,
                sourceJSON: Data(#"{"name":"old"}"#.utf8),
                isTruncated: false
            )
        }
        try model.beginEditing()
        let draft = #"{"name":"new"}"#
        model.updateDraft(draft) { draft in
            WorkspacePreparedDocumentReplacement(
                draft: draft,
                request: WorkspaceRequest(
                    method: .put,
                    path: "/logs/_doc/1",
                    body: draft.sourceJSON
                )
            )
        }
        await model.waitForValidation()

        #expect(model.hasChanges)
        #expect(model.blocksDocumentSelectionChanges)
        #expect(model.canCommit)
        #expect(model.preparedReplacement?.request.body == Data(draft.utf8))
        _ = try #require(model.beginCommit())
        model.finishCommitFailure(cancelled ? CancellationError() : WorkspaceDocumentEditingError.conflict)
        #expect(model.draftText == draft)
        #expect(model.editingState == (cancelled ? .editing : .conflicted))
        #expect(model.isCommitOutcomeUncertain == cancelled)
        #expect(!model.canCommit)
        #expect(model.loadedSnapshot?.sequenceNumber == 10)
        #expect(model.loadedSnapshot?.primaryTerm == 2)
        if cancelled {
            model.updateDraft(#"{"name":"retry"}"#) { draft in
                WorkspacePreparedDocumentReplacement(draft: draft,
                    request: WorkspaceRequest(method: .put, path: "/logs/_doc/1", body: draft.sourceJSON))
            }
            await model.waitForValidation()
            #expect(!model.canCommit)
        }

        model.discardChanges()
        #expect(!model.hasChanges)
        #expect(!model.isEditing)
        #expect(!model.isCommitOutcomeUncertain)
    }

    @Test("Refuses truncated snapshots and missing concurrency metadata")
    func unavailableSnapshots() async throws {
        let reference = WorkspaceDocumentReference(index: "logs", id: "1")
        let truncated = WorkspaceElasticsearchDocumentInspectorModel()
        await truncated.load(reference: reference) { reference in
            WorkspaceDocumentSnapshot(
                reference: reference,
                version: 1,
                sequenceNumber: 1,
                primaryTerm: 1,
                score: nil,
                sourceJSON: Data("{}".utf8),
                isTruncated: true
            )
        }
        #expect(throws: WorkspaceDocumentEditingError.self) {
            try truncated.beginEditing()
        }

        let missingVersion = WorkspaceElasticsearchDocumentInspectorModel()
        await missingVersion.load(reference: reference) { reference in
            WorkspaceDocumentSnapshot(
                reference: reference,
                version: 1,
                score: nil,
                sourceJSON: Data("{}".utf8),
                isTruncated: false
            )
        }
        #expect(throws: WorkspaceDocumentEditingError.missingConcurrencyMetadata) {
            try missingVersion.beginEditing()
        }
    }

    @Test("Stages, conflicts, and discards a document deletion")
    func stagedDeletion() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let reference = WorkspaceDocumentReference(
            index: ".ds-logs-2026.09.03-000001",
            id: "routed-1",
            routing: "tenant-a"
        )
        let snapshot = WorkspaceDocumentSnapshot(
            reference: reference,
            version: 4,
            sequenceNumber: 10,
            primaryTerm: 2,
            score: 1,
            sourceJSON: Data(#"{"name":"old"}"#.utf8),
            isTruncated: false
        )
        await model.load(reference: reference) { _ in snapshot }
        let draft = WorkspaceDocumentDeletionDraft(
            reference: reference,
            sequenceNumber: 10,
            primaryTerm: 2
        )
        let prepared = WorkspacePreparedDocumentDeletion(
            draft: draft,
            request: WorkspaceRequest(
                method: .delete,
                path: "/.ds-logs-2026.09.03-000001/_doc/routed-1"
            )
        )

        try model.stageDeletion(prepared, snapshot: snapshot)
        #expect(model.hasChanges)
        #expect(model.isPendingDeletion)
        #expect(!model.isEditing)
        #expect(model.canCommit)
        guard case .deletion = try #require(model.beginCommit()) else {
            Issue.record("Expected a staged document deletion")
            return
        }

        model.finishCommitFailure(WorkspaceDocumentEditingError.conflict)
        #expect(model.hasChanges)
        #expect(model.isPendingDeletion)
        #expect(model.editingState == .deletionConflicted)
        #expect(!model.canCommit)
        #expect(model.preparedDeletion == prepared)

        model.discardChanges()
        #expect(!model.hasChanges)
        #expect(model.loadedSnapshot == snapshot)
    }

    @Test("Finishes a committed document deletion")
    func committedDeletion() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let reference = WorkspaceDocumentReference(index: "logs", id: "1")
        let snapshot = WorkspaceDocumentSnapshot(
            reference: reference,
            version: 1,
            sequenceNumber: 3,
            primaryTerm: 1,
            score: nil,
            sourceJSON: Data("{}".utf8),
            isTruncated: false
        )
        await model.load(reference: reference) { _ in snapshot }
        let prepared = WorkspacePreparedDocumentDeletion(
            draft: WorkspaceDocumentDeletionDraft(
                reference: reference,
                sequenceNumber: 3,
                primaryTerm: 1
            ),
            request: WorkspaceRequest(
                method: .delete,
                path: "/logs/_doc/1"
            )
        )
        try model.stageDeletion(prepared, snapshot: snapshot)
        _ = try #require(model.beginCommit())

        model.finishDeletionCommit(
            WorkspaceDocumentDeletionResult(reference: reference)
        )
        #expect(!model.hasChanges)
        #expect(model.state == .empty)
    }

    @Test("Keeps a pending deletion while browsing another document")
    func pendingDeletionAllowsBrowsing() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let deletionReference = WorkspaceDocumentReference(
            index: "logs",
            id: "delete-1"
        )
        let deletionSnapshot = WorkspaceDocumentSnapshot(
            reference: deletionReference,
            version: 1,
            sequenceNumber: 3,
            primaryTerm: 1,
            score: nil,
            sourceJSON: Data(#"{"name":"delete"}"#.utf8),
            isTruncated: false
        )
        await model.load(reference: deletionReference) { _ in
            deletionSnapshot
        }
        let prepared = WorkspacePreparedDocumentDeletion(
            draft: WorkspaceDocumentDeletionDraft(
                reference: deletionReference,
                sequenceNumber: 3,
                primaryTerm: 1
            ),
            request: WorkspaceRequest(
                method: .delete,
                path: "/logs/_doc/delete-1"
            )
        )
        try model.stageDeletion(prepared, snapshot: deletionSnapshot)

        #expect(!model.blocksDocumentSelectionChanges)
        let browsedReference = WorkspaceDocumentReference(
            index: "logs",
            id: "view-2"
        )
        let browsedSnapshot = WorkspaceDocumentSnapshot(
            reference: browsedReference,
            version: 2,
            sequenceNumber: 7,
            primaryTerm: 1,
            score: nil,
            sourceJSON: Data(#"{"name":"view"}"#.utf8),
            isTruncated: false
        )
        await model.load(reference: browsedReference) { _ in
            browsedSnapshot
        }

        #expect(model.loadedSnapshot == browsedSnapshot)
        #expect(model.preparedDeletion == prepared)
        #expect(model.hasChanges)
        #expect(model.canCommit)
    }
}
