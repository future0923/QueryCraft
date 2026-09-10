import CoreFoundation
import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchDocumentPasteTests {
    private func request() -> WorkspaceDatabaseDataRowInsertRequest {
        let fields = [("name", "keyword"), ("count", "long"), ("enabled", "boolean"),
                      ("numericText", "keyword"), ("tags", "keyword"), ("profile", "object")]
        return .makeElasticsearchDocument(
            selection: .init(databaseName: "Elasticsearch", objectName: "logs-write", kind: .elasticsearchAlias),
            pageColumns: fields.enumerated().map { .init(id: $0.offset, name: $0.element.0, type: $0.element.1) })
    }

    private func parse(_ text: String, target: [String] = []) async throws -> [WorkspaceElasticsearchPastedDocument] {
        try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
            .init(internalPayload: nil, tabSeparatedText: text), targetColumnNames: target,
            request: request(), targetKind: .alias)
    }

    @Test func excelHeadersCRLFAndIndependentIdentity() async throws {
        let rows = try await parse("_id\tname\tcount\tenabled\tnumericText\t_routing\r\npaste-1\t1\t1\tfalse\t001\t\r\n\t中文\t0\ttrue\t21\ttenant-a\r\n")
        #expect(rows.count == 2)
        #expect(rows[0].draft.id == "paste-1")
        #expect(rows[1].draft.id == nil)
        #expect(rows[1].draft.routing == "tenant-a")
        #expect(rows[0].draft.targetKind == .alias)
        let json = try #require(JSONSerialization.jsonObject(with: rows[0].draft.sourceJSON) as? [String: Any])
        #expect(json["name"] as? String == "1")
        #expect(json["numericText"] as? String == "001")
        #expect(CFGetTypeID(try #require(json["count"] as? NSNumber)) != CFBooleanGetTypeID())
        #expect(CFGetTypeID(try #require(json["enabled"] as? NSNumber)) == CFBooleanGetTypeID())
        #expect(rows[0].row.drafts["name"]?.text == #""1""#)
    }

    @Test func csvQuotingArraysObjectsAndEmbeddedNewlines() async throws {
        let rows = try await parse("name,tags,profile\r\n\"沈阳,店\n第二行\",\"[\"\"a\"\",\"\"b\"\"]\",\"{\"\"age\"\":31}\"\r\n")
        let json = try #require(JSONSerialization.jsonObject(with: rows[0].draft.sourceJSON) as? [String: Any])
        #expect(json["name"] as? String == "沈阳,店\n第二行")
        #expect(json["tags"] as? [String] == ["a", "b"])
        #expect((json["profile"] as? [String: Int])?["age"] == 31)
        #expect(rows[0].sourceText.contains("\n  \"name\" : "))
        #expect(rows[0].sourceText.contains("\n    \"age\" : 31\n"))
        #expect(rows[0].sourceText.contains("\n    \"a\",\n"))
        #expect(Data(rows[0].sourceText.utf8) == rows[0].draft.sourceJSON)
    }

    @Test func nullEmptyStringAndQuotedNullStayDistinct() async throws {
        let rows = try await parse("name,numericText\nnull,\n\"\"\"null\"\"\",001\n")
        let first = try #require(JSONSerialization.jsonObject(with: rows[0].draft.sourceJSON) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: rows[1].draft.sourceJSON) as? [String: Any])
        #expect(first["name"] is NSNull)
        #expect(first["numericText"] as? String == "")
        #expect(second["name"] as? String == "null")
        #expect(rows[0].row.drafts["name"]?.mode == .null)
        #expect(rows[1].row.drafts["name"]?.text == #""null""#)
    }

    @Test func noHeadersUseSelectedColumnOrderAndPreserveLargeInteger() async throws {
        let rows = try await parse("622887501937246211\t测试\n", target: ["count", "name"])
        #expect(rows[0].sourceText.contains("622887501937246211"))
        #expect(rows[0].row.editedColumnNames == ["count", "name"])
        #expect(rows[0].draft.id == nil)
    }

    @Test(arguments: ["name,name\na,b", "name,unknown\na,b", "name,_index\na,logs"])
    func rejectsAmbiguousOrReadOnlyHeaders(_ text: String) async {
        await #expect(throws: WorkspaceElasticsearchPasteError.invalidHeader) { try await parse(text) }
    }

    @Test(arguments: ["count\nfalse", "count\n1.5", "enabled\n1", "profile\nhello"])
    func rejectsInvalidTypedValues(_ text: String) async {
        await #expect(throws: WorkspaceElasticsearchPasteError.self) { try await parse(text) }
    }

    @Test(arguments: ["name,count\na", "name\n\"unterminated", "name\n"])
    func rejectsMalformedBatchWithoutReturningPartialRows(_ text: String) async {
        await #expect(throws: WorkspaceGridPasteError.malformed) { try await parse(text) }
    }

    @Test func internalCopyKeepsNullMetadataAndTextTypes() async throws {
        let payload = WorkspaceGridClipboardPayload(columnNames: ["_index", "_id", "name", "count", "numericText"],
            rows: [[.text("actual-index"), .text("copy-id"), .text("null"), .text("1"), .null]])
        let rows = try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
            .init(internalPayload: JSONEncoder().encode(payload), tabSeparatedText: nil),
            targetColumnNames: [], request: request(), targetKind: .alias)
        #expect(rows[0].draft.id == "copy-id")
        #expect(!rows[0].sourceText.contains("_index"))
        let json = try #require(JSONSerialization.jsonObject(with: rows[0].draft.sourceJSON) as? [String: Any])
        #expect(json["name"] as? String == "null")
        #expect(json["numericText"] is NSNull)
    }

    @Test func authoritativeMappingOverridesUntypedPageColumns() async throws {
        let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
            selection: .init(databaseName: "Elasticsearch", objectName: "logs", kind: .elasticsearchIndex),
            pageColumns: [.init(id: 0, name: "name"), .init(id: 1, name: "count")])
        let fields: [WorkspaceDocumentMappingField] = [
            .init(path: "name", type: "keyword", isIndexed: true, isSearchable: true, isAggregatable: true),
            .init(path: "count", type: "long", isIndexed: true, isSearchable: true, isAggregatable: true)]
        let rows = try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
            .init(internalPayload: nil, tabSeparatedText: "\u{FEFF}name,count\n1,1"), targetColumnNames: [],
            request: request, targetKind: .index, mappingFields: fields)
        let json = try #require(JSONSerialization.jsonObject(with: rows[0].draft.sourceJSON) as? [String: Any])
        #expect(json["name"] as? String == "1")
        #expect(json["count"] as? Int == 1)
    }

    @Test func rejectsConflictingMappingAndOversizedSource() async throws {
        await #expect(throws: WorkspaceElasticsearchPasteError.invalidValue(row: 1, field: "count")) {
            try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
                .init(internalPayload: nil, tabSeparatedText: "count\n1"), targetColumnNames: [],
                request: request(), targetKind: .alias,
                mappingFields: [.init(path: "count", type: "long,keyword", isIndexed: true,
                    isSearchable: true, isAggregatable: true, hasTypeConflict: true)])
        }
        await #expect(throws: WorkspaceElasticsearchPasteError.limit) {
            try await parse("name\n" + String(repeating: "x", count: 1_024 * 1_024))
        }
    }

    @Test func boundedLargePasteAndCancellation() async throws {
        let text = "name,count\n" + (0..<500).map { "row-\($0),\($0)" }.joined(separator: "\n")
        #expect(try await parse(text).count == 500)
        await #expect(throws: WorkspaceElasticsearchPasteError.limit) { try await parse(text + "\nextra,1") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await parse(text)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func relationalParserKeepsPositionalTextSemantics() async throws {
        let rows = try await WorkspaceGridPasteParser.shared.makeDraftRows(
            from: .init(internalPayload: nil, tabSeparatedText: "name\t1\r\nNULL\tfalse\r\n"),
            targetColumnNames: ["name", "count"], request: request())
        #expect(rows.count == 2)
        #expect(rows[0].drafts["name"]?.text == "name")
        #expect(rows[0].drafts["count"]?.text == "1")
        #expect(rows[1].drafts["name"]?.mode == .null)
        #expect(rows[1].drafts["count"]?.text == "false")
    }

    @Test @MainActor func atomicAdmissionPreservesExistingDraftAndDiscardsAll() async throws {
        let root = WorkspaceElasticsearchDocumentInspectorModel()
        let oldID = UUID()
        try root.addCreation(rowID: oldID, targetName: "logs-write", targetKind: .alias, prepare: Self.prepare)
        await root.waitForValidation()
        let documents = try await parse("_id,name,count\npaste-1,first,1\n,second,2")
        let revision = root.creations.mutationRevision
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try root.creations.installPaste(documents, prepared: [], replacingEmptyRowID: nil)
        }
        #expect(root.creations.order == [oldID])
        #expect(root.creations.mutationRevision == revision)
        try root.creations.installPaste(documents, prepared: documents.map { Self.prepare($0.draft) }, replacingEmptyRowID: nil)
        #expect(root.creations.order == [oldID] + documents.map { $0.row.id })
        #expect(root.canCommit)
        #expect(root.preparedChange?.requests.count == 3)
        let child = try #require(root.creations.entries[documents[0].row.id])
        #expect(child.draftText.contains("\n  \"count\" : 1,"))
        #expect(child.draftText == documents[0].sourceText)
        #expect(child.preparedCreation?.request.body == Data(child.draftText.utf8))
        root.discardChanges()
        await root.waitForValidation()
        #expect(!root.hasChanges)
        #expect(root.creations.projections.isEmpty)
    }

    @Test @MainActor func emptyReplacementKeepsUUIDOrderAndCannotOverwritePopulatedDraft() async throws {
        let root = WorkspaceElasticsearchDocumentInspectorModel()
        let oldID = UUID()
        try root.addCreation(rowID: oldID, targetName: "logs-write", targetKind: .alias, prepare: Self.prepare)
        await root.waitForValidation()
        var documents = try await parse("name,count\na,1\nb,2")
        let first = documents[0]
        documents[0] = .init(row: .init(id: oldID, drafts: first.row.drafts, editedColumnNames: first.row.editedColumnNames),
            draft: first.draft, sourceText: first.sourceText)
        let prepared = documents.map { Self.prepare($0.draft) }
        try root.creations.installPaste(documents, prepared: prepared, replacingEmptyRowID: oldID)
        #expect(root.creations.order == documents.map { $0.row.id })
        #expect(!root.creations.isEmptyCreation(oldID))
        #expect(throws: WorkspaceDocumentEditingError.unavailable) {
            try root.creations.installPaste(documents, prepared: prepared, replacingEmptyRowID: oldID)
        }
        root.discardChanges()
    }

    @MainActor private static func prepare(_ draft: WorkspaceDocumentCreationDraft) -> WorkspacePreparedDocumentCreation {
        .init(draft: draft, request: .init(method: .post, path: "/logs-write/_doc", body: draft.sourceJSON))
    }
}
