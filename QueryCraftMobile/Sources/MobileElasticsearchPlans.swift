import Foundation
import QueryCraftMobileCore

extension MobileElasticsearchAction {
    func makePlan(_ service: any MobileElasticsearchServing) async throws -> MobileElasticsearchPlan {
        switch kind {
        case .cellChanges:
            // A foreground session may replace the one used by an interrupted validation.
            // Keep the original snapshot/version and rebuild the exact same staged edits.
            let entries = owner.cellChanges.order.compactMap { owner.cellChanges.entries[$0] }
            for entry in entries {
                try owner.cellChanges.stage(snapshot: entry.snapshot, edits: entry.edits, forceValidation: true) { draft in
                    try await service.prepareDocumentPartialUpdate(draft)
                }
            }
            await owner.cellChanges.waitForValidation()
            guard let updates = owner.cellChanges.preparedUpdates else { throw MobileElasticsearchFailure.rejected(owner.cellChanges.errorMessage ?? "没有可提交的字段修改。") }
            return .init(requests: updates.map(\.request), send: { session in
                var receipts: [String] = []
                for update in updates {
                    do { let result = try await session.commitDocumentPartialUpdate(update); receipts.append(result.reference.id) }
                    catch { if !receipts.isEmpty { throw MobileElasticsearchBatchFailure(acknowledged: receipts, failure: error.localizedDescription) }; throw error }
                }
                return receipts.joined(separator: ", ")
            }, verification: { session in
                var values: [String] = []
                for update in updates {
                    let current = try await session.fetchDocument(update.draft.reference, maximumByteCount: 1_048_576)
                    values.append(current.reference.id + "\n" + String(decoding: current.sourceJSON, as: UTF8.self))
                }
                return values.joined(separator: "\n\n")
            })
        case .batchDelete:
            guard let page = owner.page, !selectedRows.isEmpty else { throw MobileElasticsearchFailure.rejected("请选择要删除的文档。") }
            var deletions: [WorkspacePreparedDocumentDeletion] = []
            for index in selectedRows.sorted() {
                guard let row = page.row(at: index), let reference = owner.documentReference(row: row, columns: page.columns) else { throw MobileElasticsearchFailure.stale }
                let snapshot = try await service.fetchDocument(reference, maximumByteCount: 1_048_576)
                guard let sequence = snapshot.sequenceNumber, let term = snapshot.primaryTerm else { throw WorkspaceDocumentEditingError.missingConcurrencyMetadata }
                deletions.append(try await service.prepareDocumentDeletion(.init(reference: snapshot.reference, sequenceNumber: sequence, primaryTerm: term)))
            }
            let prepared = deletions
            return .init(requests: prepared.map(\.request), send: { session in
                var receipts: [String] = []
                for item in prepared {
                    do { let result = try await session.commitDocumentDeletion(item); receipts.append(result.reference.index + "/" + result.reference.id) }
                    catch { if !receipts.isEmpty { throw MobileElasticsearchBatchFailure(acknowledged: receipts, failure: error.localizedDescription) }; throw error }
                }
                return "已删除 \(receipts.count) 篇文档\n" + receipts.joined(separator: "\n")
            }, verification: { session in
                var results: [String] = []
                for item in prepared {
                    let reference = item.draft.reference
                    let request = WorkspaceRequest(method: .get, path: "/" + MobileResourceService.pathComponent(reference.index) + "/_doc/" + MobileResourceService.pathComponent(reference.id) + (reference.routing.map { "?routing=" + MobileResourceService.pathComponent($0) } ?? ""))
                    let response = try await session.executeRequest(request)
                    guard response.statusCode == 200 || response.statusCode == 404 else { throw MobileElasticsearchFailure.rejected("核实被拒绝 HTTP \(response.statusCode)") }
                    results.append(reference.id + " · HTTP \(response.statusCode)")
                }
                return results.joined(separator: "\n")
            })
        case .document:
            guard let snapshot = document else { throw MobileElasticsearchFailure.unavailable }
            guard !snapshot.isTruncated else { throw WorkspaceDocumentEditingError.sourceTooLarge(1_048_576) }
            guard let sequence = snapshot.sequenceNumber, let term = snapshot.primaryTerm else { throw WorkspaceDocumentEditingError.missingConcurrencyMetadata }
            let reference = snapshot.reference
            let verification: @Sendable (any MobileElasticsearchServing) async throws -> String = { session in
                let path = "/" + MobileResourceService.pathComponent(reference.index) + "/_doc/" + MobileResourceService.pathComponent(reference.id) + (reference.routing.map { "?routing=" + MobileResourceService.pathComponent($0) } ?? "")
                let response = try await session.executeRequest(.init(method: .get, path: path))
                guard response.statusCode == 200 || response.statusCode == 404 else { throw MobileElasticsearchFailure.rejected("核实失败 HTTP \(response.statusCode)") }
                return String(decoding: response.body, as: UTF8.self)
            }
            if mode == "delete" {
                let prepared = try await service.prepareDocumentDeletion(.init(reference: reference, sequenceNumber: sequence, primaryTerm: term))
                return .init(requests: [prepared.request], send: { session in
                    let result = try await session.commitDocumentDeletion(prepared)
                    return "已删除 \(result.reference.index)/\(result.reference.id)"
                }, verification: verification)
            }
            let bytes = try await WorkspaceElasticsearchDocumentValidator().validate(source)
            if mode == "partial" {
                let prepared = try await service.prepareDocumentPartialUpdate(.init(reference: reference, sequenceNumber: sequence, primaryTerm: term, sourceJSON: snapshot.sourceJSON, changedFieldsJSON: bytes))
                return .init(requests: [prepared.request], send: { session in
                    let result = try await session.commitDocumentPartialUpdate(prepared)
                    return "版本 \(result.version.map(String.init) ?? "—") · seq_no \(result.sequenceNumber)"
                }, verification: verification)
            }
            let prepared = try await service.prepareDocumentReplacement(.init(reference: reference, sequenceNumber: sequence, primaryTerm: term, sourceJSON: bytes))
            return .init(requests: [prepared.request], send: { session in
                let result = try await session.commitDocumentReplacement(prepared)
                return "版本 \(result.version.map(String.init) ?? "—") · seq_no \(result.sequenceNumber)"
            }, verification: verification)
        case .createDocument, .pasteDocuments:
            guard let object else { throw MobileElasticsearchFailure.unavailable }
            let target: WorkspaceDocumentCreationTargetKind = object.kind == .elasticsearchAlias ? .alias : object.kind == .elasticsearchDataStream ? .dataStream : .index
            let drafts: [WorkspaceDocumentCreationDraft]
            if kind == .pasteDocuments {
                guard let selection, let page = owner.page else { throw MobileElasticsearchFailure.unavailable }
                let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(selection: selection, pageColumns: page.columns)
                let parsed = try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(.init(internalPayload: nil, tabSeparatedText: source), targetColumnNames: page.columns.map(\.name), request: request, targetKind: target, mappingFields: owner.mapping?.fieldCapabilities ?? [])
                drafts = parsed.map(\.draft)
                guard !drafts.isEmpty else { throw WorkspaceGridPasteError.unavailable }
            } else {
                let bytes = try await WorkspaceElasticsearchDocumentValidator().validate(source)
                drafts = [.init(targetName: object.name, targetKind: target, id: documentID.isEmpty ? nil : documentID, routing: routing.isEmpty ? nil : routing, sourceJSON: bytes)]
            }
            var prepared: [WorkspacePreparedDocumentCreation] = []
            for draft in drafts { prepared.append(try await service.prepareDocumentCreation(draft)) }
            let creations = prepared
            return .init(requests: creations.map(\.request), send: { session in
                var receipts: [String] = []
                for creation in creations {
                    do {
                        let result = try await session.commitDocumentCreation(creation)
                        receipts.append("\(result.reference.index)/\(result.reference.id)")
                    } catch {
                        if !receipts.isEmpty { throw MobileElasticsearchBatchFailure(acknowledged: receipts, failure: error.localizedDescription) }
                        throw error
                    }
                }
                return receipts.joined(separator: "\n")
            }, verification: { session in
                let response = try await session.executeRequest(.init(method: .post, path: "/" + MobileResourceService.pathComponent(object.name) + "/_search", body: Data("{\"size\":100,\"sort\":[\"_doc\"]}".utf8)))
                try MobileElasticsearchFailure.accepted(response)
                return String(decoding: response.body, as: UTF8.self)
            })
        case .mapping:
            guard let mapping else { throw MobileElasticsearchFailure.unavailable }
            let path = try JSONDecoder().decode([String].self, from: Data(mappingPath.utf8))
            let definition = try await WorkspaceElasticsearchDocumentValidator().validate(source)
            let prepared = try await service.prepareMappingUpdate(.init(baseline: mapping, changes: [.init(path: path, definitionJSON: definition, isNew: mappingIsNew)]))
            return .init(requests: [prepared.request], preflight: { session in
                let current = try await session.fetchMappingSnapshot(mapping.target)
                try WorkspaceMappingCodec.validateBaseline(prepared.draft, current: current)
            }, send: { session in try MobileElasticsearchFailure.acknowledged(try await session.commitMappingUpdate(prepared)) }, verification: { session in
                let current = try await session.fetchMappingSnapshot(mapping.target)
                return String(decoding: current.rawJSON, as: UTF8.self)
            })
        case .createIndex:
            let worker = WorkspaceIndexCreationWorker()
            let prepared = try await worker.prepare(.init(name: name, shards: shards, replicas: replicas, mapping: source))
            return .init(requests: [prepared.request], send: { session in
                let response = try await session.executeRequest(prepared.request, policy: .writesAllowed)
                switch await worker.outcome(response, name: prepared.input.name) {
                case .created(let waiting): return waiting ? "索引已创建，分片仍待就绪。" : "索引已创建。"
                case .rejected: throw MobileElasticsearchFailure.rejected(String(decoding: response.body, as: UTF8.self))
                case .uncertain: throw MobileElasticsearchFailure.uncertain
                }
            }, verification: { session in
                let response = try await session.executeRequest(prepared.verificationRequest)
                guard response.statusCode == 200 || response.statusCode == 404 else { throw MobileElasticsearchFailure.rejected("核实失败 HTTP \(response.statusCode)") }
                return "索引当前状态 HTTP \(response.statusCode)"
            })
        case .deleteIndex:
            guard let selection, name == selection.objectName else { throw MobileElasticsearchFailure.rejected("请输入完整索引名称确认删除。") }
            let worker = WorkspaceIndexDeletionWorker()
            let prepared = try await worker.prepare(selection)
            return .init(requests: [prepared.request], preflight: { session in
                let response = try await session.executeRequest(prepared.resolutionRequest)
                guard try await worker.validateResolution(response, for: prepared) else { throw MobileElasticsearchFailure.rejected("索引已经不存在。") }
            }, send: { session in
                let response = try await session.executeRequest(prepared.request, policy: .writesAllowed)
                switch await worker.outcome(response) {
                case .deleted: return "索引已删除。"
                case .absent: return "索引已不存在。"
                case .rejected: throw MobileElasticsearchFailure.rejected(String(decoding: response.body, as: UTF8.self))
                case .uncertain: throw MobileElasticsearchFailure.uncertain
                }
            }, verification: { session in
                let response = try await session.executeRequest(prepared.verificationRequest)
                guard response.statusCode == 200 || response.statusCode == 404 else { throw MobileElasticsearchFailure.rejected("核实失败 HTTP \(response.statusCode)") }
                return "索引当前状态 HTTP \(response.statusCode)"
            })
        case .settings:
            guard let settings, let selection else { throw MobileElasticsearchFailure.unavailable }
            let worker = WorkspaceIndexSettingsWorker()
            let prepared = try await worker.prepare(settings, replicas: replicas, interval: secondary)
            try await worker.validatePrepared(prepared)
            let request = try await worker.settingsRequest(selection)
            return .init(requests: [prepared.request], preflight: { session in
                try await worker.validateBaseline(prepared, response: session.executeRequest(request))
            }, send: { session in try MobileElasticsearchFailure.acknowledged(try await session.executeRequest(prepared.request, policy: .writesAllowed)) }, verification: { session in
                let response = try await session.executeRequest(request); try MobileElasticsearchFailure.accepted(response)
                return String(decoding: response.body, as: UTF8.self)
            })
        case .aliases:
            guard let aliases else { throw MobileElasticsearchFailure.unavailable }
            let worker = WorkspaceElasticsearchAliasWorker()
            let prepared = try await worker.prepare(snapshot: aliases, rows: aliasRows)
            try await worker.validatePrepared(prepared)
            let request = try await worker.readRequest(aliases.selection)
            return .init(requests: [prepared.request], preflight: { session in
                try await worker.validateBaseline(prepared, response: session.executeRequest(request))
            }, send: { session in try MobileElasticsearchFailure.acknowledged(try await session.executeRequest(prepared.request, policy: .writesAllowed)) }, verification: { session in
                let response = try await session.executeRequest(request); try MobileElasticsearchFailure.accepted(response)
                return String(decoding: response.body, as: UTF8.self)
            })
        case .templates:
            let worker = WorkspaceElasticsearchIndexTemplateWorker()
            let prepared: WorkspacePreparedElasticsearchIndexTemplateMutation
            if mode == "delete", let templateBaseline { prepared = try await worker.prepareDeletion(templateBaseline) }
            else { prepared = try await worker.prepareSave(input: .init(name: name, source: source), baseline: templateBaseline) }
            try await worker.validatePrepared(prepared)
            return .init(requests: [prepared.request], preflight: { session in
                try await worker.validateBaseline(prepared, response: session.executeRequest(prepared.verificationRequest))
            }, send: { session in try MobileElasticsearchFailure.acknowledged(try await session.executeRequest(prepared.request, policy: .writesAllowed)) }, verification: { session in
                let response = try await session.executeRequest(prepared.verificationRequest)
                guard response.statusCode == 200 || response.statusCode == 404 else { throw MobileElasticsearchFailure.rejected("核实失败 HTTP \(response.statusCode)") }
                return String(decoding: response.body, as: UTF8.self)
            })
        case .simulate: throw MobileElasticsearchFailure.unavailable
        }
    }

}
