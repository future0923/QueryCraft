import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchMappingTests {
    @Test func objectReadbackAcceptsImplicitType() throws {
        let before = try snapshot(#"{"logs":{"mappings":{"properties":{}}}}"#)
        let after = try snapshot(#"{"logs":{"mappings":{"properties":{"profile":{"properties":{"city":{"type":"keyword"}}}}}}}"#)
        let draft = WorkspaceMappingDraft(baseline: before, changes: [
            .init(path: ["properties", "profile"], definitionJSON: Data(#"{"type":"object"}"#.utf8), isNew: true),
            .init(path: ["properties", "profile", "properties", "city"], definitionJSON: Data(#"{"type":"keyword"}"#.utf8), isNew: true)])
        #expect(try WorkspaceMappingCodec.containsChanges(draft, current: after))
    }
    private func snapshot(_ json: String = #"{"logs":{"mappings":{"properties":{"name":{"type":"text"},"count":{"type":"integer"},"profile":{"type":"object","properties":{"city":{"type":"keyword","ignore_above":256}}}}}}}"#) throws -> WorkspaceMappingSnapshot {
        try WorkspaceMappingCodec.snapshot(target: .init(resource: "logs", kind: .elasticsearchIndex), data: Data(json.utf8))
    }

    @Test func minimalNestedAndMultiFieldRequest() throws {
        let baseline = try snapshot()
        let draft = WorkspaceMappingDraft(baseline: baseline, changes: [
            .init(path: ["properties", "name", "fields", "keyword"], definitionJSON: Data(#"{"type":"keyword","ignore_above":512}"#.utf8), isNew: true),
            .init(path: ["properties", "profile", "properties", "city"], definitionJSON: Data(#"{"ignore_above":1024}"#.utf8), isNew: false),
            .init(path: ["properties", "enabled"], definitionJSON: Data(#"{"type":"boolean"}"#.utf8), isNew: true)
        ])
        let prepared = try WorkspaceMappingCodec.prepare(draft)
        #expect(prepared.request.method == .put)
        #expect(prepared.request.path == "/logs/_mapping")
        let body = try WorkspaceMappingCodec.object(#require(prepared.request.body))
        let properties = try #require(body["properties"] as? [String: Any])
        #expect(properties["count"] == nil)
        let name = try #require(properties["name"] as? [String: Any])
        #expect(name["type"] as? String == "text")
        #expect((name["fields"] as? [String: Any])?["keyword"] != nil)
        #expect(name["properties"] == nil)
    }

    @Test(arguments: [#"{"type":"keyword"}"#, #"{"type":"text","index":false}"#, #"{"type":"text","eager_global_ordinals":"false"}"#])
    func rejectsExistingTypeOrUnsupportedParameterChanges(definition: String) throws {
        let draft = WorkspaceMappingDraft(baseline: try snapshot(), changes: [.init(path: ["properties", "name"], definitionJSON: Data(definition.utf8), isNew: false)])
        #expect(throws: WorkspaceMappingError.self) { try WorkspaceMappingCodec.prepare(draft) }
    }

    @Test func detectsExternalChangesAndAllowsUnrelatedFields() throws {
        let baseline = try snapshot()
        let change = WorkspaceMappingFieldChange(path: ["properties", "profile", "properties", "city"], definitionJSON: Data(#"{"ignore_above":512}"#.utf8), isNew: false)
        let draft = WorkspaceMappingDraft(baseline: baseline, changes: [change])
        let changed = try snapshot(String(decoding: baseline.rawJSON, as: UTF8.self).replacingOccurrences(of: "256", with: "128"))
        #expect(throws: WorkspaceMappingError.self) { try WorkspaceMappingCodec.validateBaseline(draft, current: changed) }
        let unrelated = try snapshot(String(decoding: baseline.rawJSON, as: UTF8.self).replacingOccurrences(of: "\"integer\"", with: "\"long\""))
        try WorkspaceMappingCodec.validateBaseline(draft, current: unrelated)
        #expect(try !WorkspaceMappingCodec.containsChanges(draft, current: baseline))
        let applied = try snapshot(String(decoding: baseline.rawJSON, as: UTF8.self).replacingOccurrences(of: "256", with: "512"))
        #expect(try WorkspaceMappingCodec.containsChanges(draft, current: applied))
    }

    @Test func defaultsAndStableDraftIdentity() async throws {
        let snapshot = try snapshot()
        let worker = WorkspaceMappingEditorWorker()
        let original = try await worker.rows(snapshot)
        var rows = original
        let index = try #require(rows.firstIndex { $0.name == "count" })
        let id = rows[index].id
        rows[index].parameters["coerce"] = "false"
        let draft = try await worker.draft(snapshot: snapshot, rows: rows, originals: original)
        #expect(rows[index].id == id)
        let value = try WorkspaceMappingCodec.object(#require(draft.changes.first).definitionJSON)
        #expect(value["coerce"] as? Bool == false)
        #expect(value["index"] == nil)
        rows[index] = original[index]
        #expect(try await worker.draft(snapshot: snapshot, rows: rows, originals: original).changes.isEmpty)
    }

    @Test func preventsAliasAndMissingParentWrites() throws {
        let baseline = try snapshot()
        let invalid = WorkspaceMappingDraft(baseline: baseline, changes: [.init(path: ["properties", "missing", "properties", "child"], definitionJSON: Data(#"{"type":"keyword"}"#.utf8), isNew: true)])
        #expect(throws: WorkspaceMappingError.self) { try WorkspaceMappingCodec.prepare(invalid) }
        let alias = try WorkspaceMappingCodec.snapshot(target: .init(resource: "alias", kind: .elasticsearchAlias), data: baseline.rawJSON)
        #expect(throws: WorkspaceMappingError.self) { try WorkspaceMappingCodec.prepare(.init(baseline: alias, changes: invalid.changes)) }
    }
}
