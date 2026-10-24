import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized) @MainActor struct MobileElasticsearchTests {
    nonisolated static var port: Int? { ProcessInfo.processInfo.environment["PROOF_ELASTICSEARCH_PORT"].flatMap(Int.init) }
    static func profile(port: Int) -> MobileConnectionProfile {
        .init(id: UUID(), name: "ES 隔离验证", host: "127.0.0.1", port: port, username: "", database: "", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .elasticsearch, authentication: .none)
    }
    private func fixture() async throws -> (MobileElasticsearchWorkspace, String, any MobileElasticsearchServing) {
        let port = try #require(Self.port)
        let model = MobileElasticsearchWorkspace(profile: Self.profile(port: port), password: nil)
        let service = try await model.ready()
        let name = "qc-mobile-es-" + UUID().uuidString.lowercased()
        let body = Data(#"{"settings":{"number_of_shards":1,"number_of_replicas":0},"mappings":{"properties":{"name":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"count":{"type":"integer"},"flag":{"type":"boolean"},"nested":{"properties":{"value":{"type":"keyword"}}}}}}"#.utf8)
        let response = try await service.executeRequest(.init(method: .put, path: "/" + name, body: body), policy: .writesAllowed)
        try MobileElasticsearchFailure.accepted(response)
        return (model, name, service)
    }
    private func cleanup(_ service: any MobileElasticsearchServing, name: String) async {
        _ = try? await service.executeRequest(.init(method: .delete, path: "/" + name), policy: .writesAllowed)
        await service.close()
    }
    private func create(_ service: any MobileElasticsearchServing, index: String, id: String = "one", source: String = #"{"name":"雪","count":1,"flag":true}"#, routing: String? = nil) async throws -> WorkspaceDocumentCreationResult {
        let prepared = try await service.prepareDocumentCreation(.init(targetName: index, targetKind: .index, id: id, routing: routing, sourceJSON: Data(source.utf8)))
        return try await service.commitDocumentCreation(prepared)
    }
    @Test(.enabled(if: port != nil)) func workspaceBrowseFilterSortRefresh() async throws {
        let (model, name, service) = try await fixture()
        _ = try await create(service, index: name)
        _ = try await create(service, index: name, id: "two", source: #"{"name":"other","count":20,"flag":false}"#)
        await model.loadCatalog()?.value
        let object = try #require(model.catalog?.first { $0.name == name })
        model.select(object); await model.loadPage(offset: 0, fresh: true)?.value
        #expect(model.page?.rowCount == 2); #expect(model.mapping?.fieldCapabilities.contains { $0.path == "name.keyword" } == true)
        #expect(model.data.columns.contains("_routing")); #expect(model.pageError == nil)
        model.apply(filter: .init(conditions: [.init(columnName: "count", columnKind: .elasticsearchNumber, operation: .rangeGreaterThan, value: "10")]))
        await model.loadPage(offset: 0, fresh: true)?.value
        #expect(model.page?.rowCount == 1); #expect(model.totalCount == 1)
        model.setSort(.descending(columnName: "count")); await model.loadPage(offset: 0, fresh: true)?.value
        #expect(model.page?.filter.isActive == true)
        await cleanup(service, name: name)
    }
    @Test(.enabled(if: port != nil)) func deepPITPagingPastTenThousandAndExportTypes() async throws {
        let (model, name, service) = try await fixture()
        var bulk = ""
        for id in 0..<10_250 { bulk += "{\"index\":{\"_index\":\"\(name)\",\"_id\":\"\(id)\"}}\n{\"count\":\(id),\"flag\":true,\"name\":\"雪\"}\n" }
        let result = try await service.executeRequest(.init(method: .post, path: "/_bulk?refresh=true", body: Data(bulk.utf8)), policy: .writesAllowed)
        try MobileElasticsearchFailure.accepted(result)
        let root = try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any]); #expect(root["errors"] as? Bool == false)
        await model.loadCatalog()?.value; let object = try #require(model.catalog?.first { $0.name == name }); model.select(object)
        model.setPageSize(500); await model.loadPage(offset: 0, fresh: true)?.value
        var identities = Set<String>()
        for offset in stride(from: 0, through: 10_000, by: 500) {
            if offset > 0 { await model.loadPage(offset: offset)?.value }
            #expect(model.pageError == nil)
            let page = try #require(model.page); #expect(page.offset == offset)
            for row in page.rows { let reference = try #require(model.documentReference(row: row, columns: page.columns)); #expect(identities.insert(reference.id).inserted) }
        }
        #expect(identities.count == 10_250); #expect(model.page?.hasNextPage == false)
        let snapshot = model.exportSnapshot
        var options = WorkspaceDataExportPreferences().options(for: .csv); options.scope = .allTableRows
        let request = try snapshot.request(options: options)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let exported = try await WorkspaceDataExporter().export(request, to: file) { _ in }
        #expect(exported == 10_250)
        #expect((try String(contentsOf: file, encoding: .utf8)).contains("雪"))
        await model.loadPage(fresh: true)?.value
        #expect(model.page?.offset == 0); #expect(model.totalCount == 10_250)
        await cleanup(service, name: name)
    }
    @Test(.enabled(if: port != nil)) func documentConflictRoutingCreationAndDeletion() async throws {
        let (model, name, service) = try await fixture()
        let created = try await create(service, index: name, routing: "route /雪")
        let object = WorkspaceDatabaseObject(name: name, kind: .elasticsearchIndex)
        let action = MobileElasticsearchAction(owner: model, kind: .document, object: object, reference: created.reference)
        await action.reload()?.value; #expect(action.document?.reference.routing == "route /雪")
        action.source = #"{"name":"mobile","count":2}"#; await action.prepare()?.value
        #expect(action.preview?.contains("if_seq_no=") == true); #expect(action.canSubmit == false)
        model.safetyLock.disable()
        let current = try await service.fetchDocument(created.reference, maximumByteCount: 1_048_576)
        let replacement = try await service.prepareDocumentReplacement(.init(reference: created.reference, sequenceNumber: try #require(current.sequenceNumber), primaryTerm: try #require(current.primaryTerm), sourceJSON: Data(#"{"name":"external","count":3}"#.utf8)))
        _ = try await service.commitDocumentReplacement(replacement)
        await action.submit()?.value
        #expect(action.needsVerification == false); #expect(action.completed == false); #expect(action.message?.contains("变化") == true)
        await action.reload()?.value; action.mode = "partial"; action.source = #"{"count":4}"#; await action.prepare()?.value; await action.submit()?.value
        #expect(action.completed)
        let value = try await service.fetchDocument(created.reference, maximumByteCount: 1_048_576)
        let root = try #require(JSONSerialization.jsonObject(with: value.sourceJSON) as? [String: Any]); #expect(root["name"] as? String == "external"); #expect(root["count"] as? Int == 4)
        let deletion = MobileElasticsearchAction(owner: model, kind: .document, object: object, reference: created.reference)
        await deletion.reload()?.value; deletion.mode = "delete"; await deletion.prepare()?.value; await deletion.submit()?.value; #expect(deletion.completed)
        await cleanup(service, name: name)
    }
    @Test(.enabled(if: port != nil)) func indexMappingSettingsAndAliasesUseSharedPlans() async throws {
        let (model, name, service) = try await fixture()
        let object = WorkspaceDatabaseObject(name: name, kind: .elasticsearchIndex)
        model.safetyLock.disable()
        let mapping = MobileElasticsearchAction(owner: model, kind: .mapping, object: object, reference: nil)
        await mapping.reload()?.value; mapping.mappingPath = #"["properties","new_field"]"#; mapping.source = #"{"type":"keyword"}"#
        await mapping.prepare()?.value; await mapping.submit()?.value; #expect(mapping.completed)
        let settings = MobileElasticsearchAction(owner: model, kind: .settings, object: object, reference: nil)
        await settings.reload()?.value; settings.secondary = "2s"; await settings.prepare()?.value; await settings.submit()?.value; #expect(settings.completed)
        let aliases = MobileElasticsearchAction(owner: model, kind: .aliases, object: object, reference: nil)
        await aliases.reload()?.value; aliases.name = name + "-alias"; aliases.secondary = name; aliases.source = #"{"routing":"mobile","filter":{"term":{"flag":true}}}"#; aliases.addAlias()
        await aliases.prepare()?.value; await aliases.submit()?.value; #expect(aliases.completed)
        let response = try await service.executeRequest(.init(method: .get, path: "/" + name + "/_alias"))
        #expect(String(decoding: response.body, as: UTF8.self).contains("mobile"))
        await cleanup(service, name: name)
    }
    @Test(.enabled(if: port != nil)) func indexCreationDeletionAndTemplatesSimulation() async throws {
        let port = try #require(Self.port), model = MobileElasticsearchWorkspace(profile: Self.profile(port: port), password: nil)
        let service = try await model.ready(), name = "qc-mobile-admin-" + UUID().uuidString.lowercased()
        model.safetyLock.disable()
        let create = MobileElasticsearchAction(owner: model, kind: .createIndex, object: nil, reference: nil)
        await create.reload()?.value; create.name = name; create.replicas = "0"; create.source = #"{"properties":{"message":{"type":"keyword"}}}"#
        await create.prepare()?.value; await create.submit()?.value; #expect(create.completed)
        let template = MobileElasticsearchAction(owner: model, kind: .templates, object: nil, reference: nil)
        await template.reload()?.value; template.name = name + "-template"; template.source = "{\"index_patterns\":[\"\(name)-*\"],\"priority\":100,\"template\":{\"settings\":{\"number_of_replicas\":0},\"mappings\":{\"properties\":{\"message\":{\"type\":\"keyword\"}}}}}"
        await template.prepare()?.value; await template.submit()?.value; #expect(template.completed)
        let simulate = MobileElasticsearchAction(owner: model, kind: .simulate, object: nil, reference: nil)
        await simulate.reload()?.value; simulate.name = name + "-future"; await simulate.simulate()?.value; #expect(simulate.raw.contains("keyword")); #expect(simulate.message?.contains(name + "-template") == true)
        let stream = name + "-stream", streamTemplate = name + "-stream-template"
        let streamBody = Data(("{\"index_patterns\":[\"" + stream + "*\"],\"priority\":200,\"data_stream\":{},\"template\":{\"settings\":{\"number_of_replicas\":0}}}").utf8)
        _ = try await service.executeRequest(.init(method: .put, path: "/_index_template/" + streamTemplate, body: streamBody), policy: .writesAllowed)
        _ = try await service.executeRequest(.init(method: .put, path: "/_data_stream/" + stream), policy: .writesAllowed)
        let streamObject = WorkspaceDatabaseObject(name: stream, kind: .elasticsearchDataStream)
        let streamDocument = MobileElasticsearchAction(owner: model, kind: .createDocument, object: streamObject, reference: nil)
        await streamDocument.reload()?.value; streamDocument.source = #"{"@timestamp":"2026-10-24T00:00:00Z","message":"stream 雪"}"#
        await streamDocument.prepare()?.value; #expect(streamDocument.preview?.contains("op_type=create") == true); await streamDocument.submit()?.value; #expect(streamDocument.completed)
        let count = try await service.fetchDataCount(for: streamObject, in: "Elasticsearch"); #expect(count == 1)
        _ = try await service.fetchDataPage(for: streamObject, in: "Elasticsearch", offset: 0, limit: 100, sort: .none) { batch in
            #expect(batch.rows.count == 1)
            if let index = batch.columns.firstIndex(where: { $0.name == "_index" }), case .text(let value) = batch.rows[0].values[index] { #expect(value.hasPrefix(".ds-")) }
            else { Issue.record("Data Stream physical document index missing") }
        }
        _ = try await service.executeRequest(.init(method: .delete, path: "/_data_stream/" + stream), policy: .writesAllowed)
        _ = try await service.executeRequest(.init(method: .delete, path: "/_index_template/" + streamTemplate), policy: .writesAllowed)
        let deletion = MobileElasticsearchAction(owner: model, kind: .deleteIndex, object: .init(name: name, kind: .elasticsearchIndex), reference: nil)
        await deletion.reload()?.value; await deletion.prepare()?.value; #expect(deletion.preview == nil)
        deletion.name = name; await deletion.prepare()?.value; await deletion.submit()?.value; #expect(deletion.completed)
        _ = try await service.executeRequest(.init(method: .delete, path: "/_index_template/" + name + "-template"), policy: .writesAllowed)
        await service.close()
    }
    @Test(.enabled(if: port != nil)) func consoleBatchWritesReadRefreshAndPartialFailures() async throws {
        let (model, name, service) = try await fixture()
        let console = model.console!
        console.scope = "all"; console.source = "PUT /\(name)/_create/console?refresh=true\n{\"count\":5}\n\nGET /\(name)/_search\n{\"query\":{\"match_all\":{}}}"
        await console.prepare()?.value; await console.run()?.value; #expect(console.results.isEmpty)
        model.safetyLock.disable(); await console.run()?.value
        #expect(console.results.count == 2); #expect(console.history.count == 1)
        console.source = "GET /\(name)/_count"; await console.prepare()?.value; await console.run()?.value
        #expect(console.currentResult?.response.statusCode == 200)
        console.source = "DELETE /\(name)"; console.refresh()
        for _ in 0..<300 where console.isRunning { await Task.yield() }
        // Captured reads are refreshed; editor writes are never replayed by refresh.
        let exists = try await service.executeRequest(.init(method: .head, path: "/" + name)); #expect(exists.statusCode == 200)
        console.cancel(); await cleanup(service, name: name)
    }
    @Test func immutablePreviewAndBackgroundGuards() async throws {
        let model = MobileElasticsearchWorkspace(profile: Self.profile(port: 1), password: nil)
        let action = MobileElasticsearchAction(owner: model, kind: .createIndex, object: nil, reference: nil)
        #expect(action.canSubmit == false)
        action.setBackgrounded(true); #expect(action.prepare() == nil)
        model.setBackgrounded(true); #expect(model.loadCatalog() == nil); #expect(model.safetyLock.isEnabled)
        let console = model.console!; console.source = "GET /_cluster/health"; console.setBackgrounded(true)
        #expect(!console.canRun); #expect(console.prepare() == nil)
    }
    @Test(.enabled(if: port != nil)) func stagedTypedFieldsPasteAndBatchDeletion() async throws {
        let (model, name, service) = try await fixture()
        let first = try await create(service, index: name, id: "first")
        let second = try await create(service, index: name, id: "second")
        await model.loadCatalog()?.value
        let object = try #require(model.catalog?.first { $0.name == name }); model.select(object); await model.loadPage(offset: 0, fresh: true)?.value
        for reference in [first.reference, second.reference] {
            let snapshot = try await service.fetchDocument(reference, maximumByteCount: 1_048_576)
            try model.cellChanges.stage(snapshot: snapshot, edits: ["name": .text(#""true""#), "count": .text("42"), "flag": .text("false")]) { draft in try await service.prepareDocumentPartialUpdate(draft) }
        }
        await model.cellChanges.waitForValidation(); #expect(model.cellChanges.preparedUpdates?.count == 2); #expect(model.hasPendingChanges)
        let changes = MobileElasticsearchAction(owner: model, kind: .cellChanges, object: object, reference: nil)
        await changes.reload()?.value; await changes.prepare()?.value; model.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.completed); #expect(!model.cellChanges.hasChanges)
        let snapshot = try await service.fetchDocument(first.reference, maximumByteCount: 1_048_576)
        let root = try #require(JSONSerialization.jsonObject(with: snapshot.sourceJSON) as? [String: Any]); #expect(root["name"] as? String == "true"); #expect(root["count"] as? Int == 42); #expect(root["flag"] as? Bool == false)
        let paste = MobileElasticsearchAction(owner: model, kind: .pasteDocuments, object: object, reference: nil)
        await paste.reload()?.value; paste.source = "name,count,flag\n\"雪,new\",10,true\nsecond,20,false"
        await paste.prepare()?.value; #expect(paste.preview != nil); await paste.submit()?.value; #expect(paste.completed)
        await model.loadPage(fresh: true)?.value; #expect(model.page?.rowCount == 4)
        let deletion = MobileElasticsearchAction(owner: model, kind: .batchDelete, object: object, reference: nil)
        await deletion.reload()?.value; deletion.selectedRows = [0,1]; await deletion.prepare()?.value; await deletion.submit()?.value; #expect(deletion.completed)
        let count = try await service.fetchDataCount(for: object, in: "Elasticsearch"); #expect(count == 2)
        await cleanup(service, name: name)
    }

    @Test(.enabled(if: port != nil)) func realBackgroundShutdownRecreatesTransportAndRetainsVisiblePage() async throws {
        let (model, name, service) = try await fixture()
        _ = try await create(service, index: name)
        await model.loadCatalog()?.value; let object = try #require(model.catalog?.first { $0.name == name })
        model.select(object); await model.loadPage(offset: 0, fresh: true)?.value
        let revision = try #require(model.page?.revision)
        model.setBackgrounded(true); #expect(model.page?.revision == revision); #expect(model.session == nil)
        model.setBackgrounded(false)
        await model.loadPage(fresh: true)?.value
        #expect(model.pageError == nil); #expect(model.page?.rowCount == 1); #expect(model.page?.revision != revision)
        let current = try await model.ready(); await cleanup(current, name: name)
    }

    @Test(.enabled(if: port != nil)) func partialBatchDeletionRetainsAcknowledgedReceiptsAndPreventsReplay() async throws {
        let (model, name, service) = try await fixture()
        _ = try await create(service, index: name, id: "first"); _ = try await create(service, index: name, id: "second")
        await model.loadCatalog()?.value; let object = try #require(model.catalog?.first { $0.name == name })
        model.select(object); await model.loadPage(offset: 0, fresh: true)?.value
        let action = MobileElasticsearchAction(owner: model, kind: .batchDelete, object: object, reference: nil)
        await action.reload()?.value; action.selectedRows = [0,1]; await action.prepare()?.value
        let page = try #require(model.page), row = try #require(page.row(at: 1)), reference = try #require(model.documentReference(row: row, columns: page.columns))
        let snapshot = try await service.fetchDocument(reference, maximumByteCount: 1_048_576)
        let prepared = try await service.prepareDocumentDeletion(.init(reference: reference, sequenceNumber: try #require(snapshot.sequenceNumber), primaryTerm: try #require(snapshot.primaryTerm)))
        _ = try await service.commitDocumentDeletion(prepared)
        model.safetyLock.disable(); await action.submit()?.value
        #expect(action.acknowledgedWrites.count == 1); #expect(action.needsVerification); #expect(action.submit() == nil)
        await action.verify()?.value; #expect(action.verified); action.finishVerification(); #expect(action.completed)
        let count = try await service.fetchDataCount(for: object, in: "Elasticsearch"); #expect(count == 0)
        await cleanup(service, name: name)
    }

    @Test(.enabled(if: port != nil)) func stagedEditsCanRevalidateAfterBackgroundSessionReplacement() async throws {
        let (model, name, service) = try await fixture()
        let created = try await create(service, index: name)
        let snapshot = try await service.fetchDocument(created.reference, maximumByteCount: 1_048_576)
        try model.cellChanges.stage(snapshot: snapshot, edits: ["name": .text("resumed")]) { draft in try await service.prepareDocumentPartialUpdate(draft) }
        model.setBackgrounded(true); model.setBackgrounded(false)
        let action = MobileElasticsearchAction(owner: model, kind: .cellChanges, object: .init(name: name, kind: .elasticsearchIndex), reference: nil)
        await action.reload()?.value; await action.prepare()?.value
        #expect(action.preview != nil); model.safetyLock.disable(); await action.submit()?.value; #expect(action.completed)
        let current = try await model.ready(), value = try await current.fetchDocument(created.reference, maximumByteCount: 1_048_576)
        #expect(String(decoding: value.sourceJSON, as: UTF8.self).contains("resumed"))
        await cleanup(current, name: name)
    }

}
