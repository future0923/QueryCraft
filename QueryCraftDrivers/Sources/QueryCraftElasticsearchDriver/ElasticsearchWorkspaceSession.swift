import CoreFoundation
import Foundation
import OSLog
import QueryCraftFeature

actor ElasticsearchWorkspaceSession: WorkspaceSession,
    WorkspaceSessionCapabilityProviding,
    WorkspaceRequestExecutingSession,
    WorkspaceDocumentInspectorSession,
    WorkspaceDocumentEditingSession,
    WorkspaceMappingEditingSession
{
    let capabilities = WorkspaceSessionCapabilities.elasticsearch

    private static let maximumEditableDocumentBytes = 1_048_576
    private static let readOnlyDocumentFieldNames: Set<String> = [
        "_id", "_index", "_score", "_routing",
    ]

    private struct PageSignature: Hashable, Sendable {
        let resource: String
        let limit: Int
        let sort: WorkspaceDatabaseDataSort
        let filter: WorkspaceDatabaseDataFilter
    }

    private struct PageState: Sendable {
        let id: UUID
        let signature: PageSignature
        var pitID: String?
        var pitUnavailable: Bool
        var didRecoverExpiredPIT: Bool
        var cursors: [Int: Data]
    }

    private let client: ElasticsearchHTTPClient
    private let logger = Logger(
        subsystem: "io.github.future0923.QueryCraft",
        category: "ElasticsearchDriver"
    )
    private var connected = false
    private var supportsPITShardDocSort = false
    private var mappingCache: [String: ElasticsearchMappingCatalog] = [:]
    private var mappingGeneration = UUID()
    private var pageState: PageState?
    private var documentScores: [WorkspaceDocumentReference: Double] = [:]

    init(configuration: ElasticsearchConnectionConfiguration) throws {
        client = try ElasticsearchHTTPClient(configuration: configuration)
    }

    init(
        configuration: ElasticsearchConnectionConfiguration,
        protocolClasses: [AnyClass]
    ) throws {
        client = try ElasticsearchHTTPClient(
            configuration: configuration,
            protocolClasses: protocolClasses
        )
    }

    func connect() async throws {
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        guard !connected else { return }
        let response = try await client.perform(method: .get, path: "/")
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let version = (root["version"] as? [String: Any])?["number"] as? String
        else {
            throw ElasticsearchError.unsupportedProduct
        }
        let header = response.headers["x-elastic-product"]
        let tagline = root["tagline"] as? String
        guard header == "Elasticsearch"
                || tagline == "You Know, for Search"
        else {
            throw ElasticsearchError.unsupportedProduct
        }
        guard Self.isSupported(version: version) else {
            throw ElasticsearchError.unsupportedVersion(version)
        }
        supportsPITShardDocSort = Self.supportsShardDocSort(version: version)
        logger.info(
            "Connected to Elasticsearch \(version, privacy: .public); PIT shard-doc sort: \(self.supportsPITShardDocSort, privacy: .public)"
        )
        connected = true
    }

    func isConnected() async -> Bool { connected }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return ["Elasticsearch"]
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        try requireConnection()
        async let resolvedResponse = client.perform(
            method: .get,
            path: "/_resolve/index/*?expand_wildcards=all"
        )
        async let catResponse = client.perform(
            method: .get,
            path: "/_cat/indices?format=json&bytes=b&expand_wildcards=all&h=index,docs.count,store.size,health"
        )
        let (resolved, cat) = try await (resolvedResponse, catResponse)
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(
            with: resolved.body
        ) as? [String: Any],
        let catRows = try JSONSerialization.jsonObject(
            with: cat.body
        ) as? [[String: Any]]
        else {
            throw ElasticsearchError.invalidResponse
        }
        let summaries: [String: WorkspaceDatabaseObjectSummary] = Dictionary(
            uniqueKeysWithValues: catRows.compactMap {
            guard let name = $0["index"] as? String else { return nil }
            return (name, WorkspaceDatabaseObjectSummary(
                documentCount: Self.integer($0["docs.count"]),
                storageByteCount: Self.int64($0["store.size"]),
                health: $0["health"] as? String
            ))
            }
        )
        var objects: [WorkspaceDatabaseObject] = []
        for stream in root["data_streams"] as? [[String: Any]] ?? [] {
            guard let name = stream["name"] as? String else { continue }
            objects.append(WorkspaceDatabaseObject(
                name: name,
                kind: .elasticsearchDataStream,
                summary: Self.mergedSummary(
                    names: Self.names(in: stream["backing_indices"]),
                    summaries: summaries
                )
            ))
        }
        for alias in root["aliases"] as? [[String: Any]] ?? [] {
            guard let name = alias["name"] as? String else { continue }
            objects.append(WorkspaceDatabaseObject(
                name: name,
                kind: .elasticsearchAlias,
                summary: Self.mergedSummary(
                    names: Self.names(in: alias["indices"]),
                    summaries: summaries
                )
            ))
        }
        for index in root["indices"] as? [[String: Any]] ?? [] {
            guard let name = index["name"] as? String else { continue }
            objects.append(WorkspaceDatabaseObject(
                name: name,
                kind: .elasticsearchIndex,
                summary: summaries[name]
            ))
        }
        return objects.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        let mapping = try await mapping(for: object.name)
        return WorkspaceDatabaseObjectDetails(
            columns: mapping.fields.map {
                WorkspaceDatabaseColumn(
                    name: $0.path,
                    type: $0.type,
                    collation: nil,
                    isNullable: true,
                    key: $0.isIndexed ? "INDEXED" : "",
                    defaultValue: nil,
                    extra: $0.isSearchable ? "SEARCHABLE" : "",
                    comment: $0.isAggregatable ? "AGGREGATABLE" : ""
                )
            },
            ddl: "",
            documentMappingFields: mapping.fields
        )
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] { [] }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try await fetchDataPage(
            for: object,
            in: database,
            offset: offset,
            limit: limit,
            sort: sort,
            filter: .empty,
            onBatch: onBatch
        )
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try requireConnection()
        let boundedLimit = max(1, min(limit, 500))
        let mapping = try await mapping(for: object.name)
        let signature = PageSignature(
            resource: object.name,
            limit: boundedLimit,
            sort: sort,
            filter: filter
        )
        if pageState?.signature != signature {
            await resetPaging()
            pageState = PageState(
                id: UUID(),
                signature: signature,
                pitID: nil,
                pitUnavailable: !supportsPITShardDocSort,
                didRecoverExpiredPIT: false,
                cursors: [0: Data("[]".utf8)]
            )
        }
        try validate(sort: sort, mapping: mapping)
        guard var state = pageState else { throw CancellationError() }
        let pagingID = state.id
        if state.pitID == nil && !state.pitUnavailable {
            do {
                let pitID = try await openPIT(resource: object.name)
                guard pageState?.id == pagingID else {
                    await closePIT(pitID)
                    throw CancellationError()
                }
                state.pitID = pitID
            } catch ElasticsearchError.forbidden {
                guard pageState?.id == pagingID else {
                    throw CancellationError()
                }
                state.pitUnavailable = true
            }
            pageState = state
        }
        let hasCursor = offset == 0 || state.cursors[offset] != nil
        if (state.pitID == nil || !hasCursor) && offset > 10_000 - boundedLimit {
            throw ElasticsearchError.deepPageUnavailable
        }

        let query = try ElasticsearchFilterTranslator.query(
            for: filter,
            mapping: mapping
        )
        let usesSearchAfter = state.pitID != nil && offset > 0
            && state.cursors[offset] != nil
        let requestedSize = usesSearchAfter ? boundedLimit + 1 : boundedLimit
        var body: [String: Any] = [
            "size": requestedSize,
            "query": query,
            "_source": true,
            "version": true,
            "stored_fields": ["_routing"],
            "track_total_hits": false,
        ]
        body["sort"] = sortBody(sort, usesPIT: state.pitID != nil)
        let path: String
        if let pitID = state.pitID {
            body["pit"] = ["id": pitID, "keep_alive": "1m"]
            path = "/_search"
            if let cursorData = state.cursors[offset], offset > 0 {
                body["search_after"] = try JSONSerialization.jsonObject(
                    with: cursorData
                )
            } else if offset > 0 && offset <= 10_000 {
                body["from"] = offset
            }
        } else {
            guard offset <= 10_000 - boundedLimit else {
                throw ElasticsearchError.deepPageUnavailable
            }
            body["from"] = offset
            path = "/\(Self.pathComponent(object.name))/_search"
        }
        logger.info(
            "Loading documents; PIT: \(state.pitID != nil, privacy: .public); tie-breaker: \(state.pitID != nil ? "_shard_doc" : "_doc", privacy: .public)"
        )
        let response: ElasticsearchHTTPClient.Response
        do {
            response = try await client.perform(
                method: .post,
                path: path,
                body: try JSONSerialization.data(withJSONObject: body),
                maximumResponseBytes: .max
            )
        } catch is CancellationError {
            if pageState?.id == pagingID { await resetPaging() }
            throw CancellationError()
        } catch ElasticsearchError.pitExpired {
            guard pageState?.id == pagingID,
                  !state.didRecoverExpiredPIT
            else { throw ElasticsearchError.pitExpired }
            await resetPaging()
            pageState = PageState(
                id: UUID(),
                signature: signature,
                pitID: nil,
                pitUnavailable: false,
                didRecoverExpiredPIT: true,
                cursors: [0: Data("[]".utf8)]
            )
            return try await fetchDataPage(
                for: object,
                in: database,
                offset: offset,
                limit: limit,
                sort: sort,
                filter: filter,
                onBatch: onBatch
            )
        }
        try Task.checkCancellation()
        guard pageState?.id == pagingID else { throw CancellationError() }
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let hitsObject = root["hits"] as? [String: Any],
        var hits = hitsObject["hits"] as? [[String: Any]]
        else {
            throw ElasticsearchError.invalidResponse
        }
        let hasNext = (state.pitID != nil || offset + boundedLimit < 10_000)
            && (hits.count > boundedLimit
                || (!usesSearchAfter && hits.count == boundedLimit))
        if hits.count > boundedLimit { hits.removeLast() }
        let batch = try makeBatch(
            hits: hits,
            offset: offset,
            mapping: mapping
        )
        if state.pitID != nil,
           let lastSort = hits.last?["sort"] as? [Any], !hits.isEmpty {
            guard var current = pageState, current.id == pagingID else {
                throw CancellationError()
            }
            current.cursors[offset + boundedLimit] = try JSONSerialization.data(
                withJSONObject: lastSort
            )
            if let renewedPIT = root["pit_id"] as? String {
                current.pitID = renewedPIT
            }
            pageState = current
        }
        await onBatch(batch)
        return WorkspaceDatabaseDataFetchResult(
            columns: batch.columns,
            hasNextPage: hasNext
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        try await fetchDataCount(for: object, in: database, filter: .empty)
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        let mapping = try await mapping(for: object.name)
        let body = ["query": try ElasticsearchFilterTranslator.query(
            for: filter,
            mapping: mapping
        )]
        let response = try await client.perform(
            method: .post,
            path: "/\(Self.pathComponent(object.name))/_count",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let count = Self.integer(root["count"])
        else { throw ElasticsearchError.invalidResponse }
        return count
    }

    func executeRequest(
        _ request: WorkspaceRequest
    ) async throws -> WorkspaceRequestExecutionResult {
        try await executeRequest(request, policy: .readOnly)
    }

    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        try requireConnection()
        try ElasticsearchReadOnlyRequestPolicy.validate(request, policy: policy)
        let isWrite = WorkspaceRequestClassifier.requiresWriteAccess(request)
        do {
        let response = try await client.perform(
            method: request.method,
            path: request.path,
            body: request.body,
            // User-authored query responses are loaded in full, like DBX.
            // AsyncBytes still consumes cancellable chunks off the UI executor.
            maximumResponseBytes: .max,
            enforceReadOnlyPolicy: policy == .readOnly,
            preserveCompletedResponse: isWrite,
            acceptsHTTPError: true
        )
        if isWrite { await invalidateAfterRequestWrite() }
        return WorkspaceRequestExecutionResult(
            statusCode: response.statusCode,
            contentType: response.contentType,
            body: response.body
        )
        } catch {
            if isWrite { await invalidateAfterRequestWrite() }
            throw error
        }
    }

    private func invalidateAfterRequestWrite() async {
        mappingGeneration = UUID()
        mappingCache.removeAll()
        documentScores.removeAll()
        await resetPaging()
    }

    func fetchMappingSnapshot(_ target: WorkspaceMappingTarget) async throws -> WorkspaceMappingSnapshot {
        try requireConnection()
        guard !target.resource.isEmpty, !target.resource.contains("*"), !target.resource.contains(","),
              [.elasticsearchIndex, .elasticsearchAlias, .elasticsearchDataStream].contains(target.kind) else { throw WorkspaceMappingError.invalidDraft }
        let encoded = Self.pathComponent(target.resource)
        let resolved = try await client.perform(method: .get, path: "/_resolve/index/\(encoded)?expand_wildcards=all")
        let root = try WorkspaceMappingCodec.object(resolved.body)
        let key = target.kind == .elasticsearchAlias ? "aliases" : target.kind == .elasticsearchDataStream ? "data_streams" : "indices"
        guard (root[key] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == target.resource }) else { throw WorkspaceMappingError.conflict }
        let response = try await client.perform(method: .get, path: "/\(encoded)/_mapping", maximumResponseBytes: .max)
        let caps = try await client.perform(method: .post, path: "/\(encoded)/_field_caps?fields=*", body: Data("{}".utf8))
        let catalog = try ElasticsearchMappingCatalog.parse(mappingData: response.body, fieldCapsData: caps.body)
        return try WorkspaceMappingCodec.snapshot(target: target, data: response.body, fieldCapabilities: catalog.fields)
    }

    func prepareMappingUpdate(_ draft: WorkspaceMappingDraft) async throws -> WorkspacePreparedMappingUpdate {
        try requireConnection()
        return try WorkspaceMappingCodec.prepare(draft)
    }

    func commitMappingUpdate(_ prepared: WorkspacePreparedMappingUpdate) async throws -> WorkspaceRequestExecutionResult {
        try requireConnection()
        guard try WorkspaceMappingCodec.prepare(prepared.draft) == prepared else { throw WorkspaceMappingError.invalidDraft }
        let current = try await fetchMappingSnapshot(prepared.draft.baseline.target)
        try WorkspaceMappingCodec.validateBaseline(prepared.draft, current: current)
        try Task.checkCancellation()
        return try await executeRequest(prepared.request, policy: .writesAllowed)
    }

    func fetchDocument(
        _ reference: WorkspaceDocumentReference,
        maximumByteCount: Int
    ) async throws -> WorkspaceDocumentSnapshot {
        try requireConnection()
        var path = "/\(Self.pathComponent(reference.index))/_doc/\(Self.pathComponent(reference.id))"
        if let routing = reference.routing, !routing.isEmpty {
            path += "?routing=\(Self.queryComponent(routing))"
        }
        let response = try await client.perform(
            method: .get,
            path: path,
            maximumResponseBytes: max(maximumByteCount * 2, 1_024)
        )
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let source = root["_source"]
        else { throw ElasticsearchError.invalidResponse }
        let pretty = try JSONSerialization.data(
            withJSONObject: source,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let limit = max(0, maximumByteCount)
        let truncated = pretty.count > limit
        return WorkspaceDocumentSnapshot(
            reference: WorkspaceDocumentReference(
                index: reference.index,
                id: reference.id,
                routing: reference.routing ?? root["_routing"] as? String
            ),
            version: Self.integer(root["_version"]),
            sequenceNumber: Self.int64(root["_seq_no"]),
            primaryTerm: Self.int64(root["_primary_term"]),
            score: documentScores[reference],
            sourceJSON: truncated ? pretty.prefix(limit) : pretty,
            isTruncated: truncated
        )
    }

    func prepareDocumentReplacement(
        _ draft: WorkspaceDocumentReplacementDraft
    ) async throws -> WorkspacePreparedDocumentReplacement {
        try requireConnection()
        return try Self.preparedDocumentReplacement(draft)
    }

    func prepareDocumentCreation(
        _ draft: WorkspaceDocumentCreationDraft
    ) async throws -> WorkspacePreparedDocumentCreation {
        try requireConnection()
        return try Self.preparedDocumentCreation(draft)
    }

    func commitDocumentCreation(
        _ creation: WorkspacePreparedDocumentCreation
    ) async throws -> WorkspaceDocumentCreationResult {
        try requireConnection()
        let expected = try Self.preparedDocumentCreation(creation.draft)
        guard expected == creation else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        let response: ElasticsearchHTTPClient.Response
        do {
            response = try await client.perform(
                method: creation.request.method,
                path: creation.request.path,
                body: creation.request.body,
                maximumResponseBytes: 1_048_576,
                preserveCompletedResponse: true
            )
        } catch ElasticsearchError.server(let status, _) where status == 409 {
            throw WorkspaceDocumentEditingError.documentAlreadyExists
        }
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        root["result"] as? String == "created",
        let index = root["_index"] as? String,
        let id = root["_id"] as? String,
        !index.isEmpty,
        !id.isEmpty,
        let sequenceNumber = Self.int64(root["_seq_no"]),
        let primaryTerm = Self.int64(root["_primary_term"])
        else {
            throw ElasticsearchError.invalidResponse
        }
        await resetPaging()
        documentScores.removeAll(keepingCapacity: false)
        return WorkspaceDocumentCreationResult(
            reference: WorkspaceDocumentReference(
                index: index,
                id: id,
                routing: creation.draft.routing
            ),
            version: Self.integer(root["_version"]),
            sequenceNumber: sequenceNumber,
            primaryTerm: primaryTerm
        )
    }

    func commitDocumentReplacement(
        _ replacement: WorkspacePreparedDocumentReplacement
    ) async throws -> WorkspaceDocumentReplacementResult {
        try requireConnection()
        let expected = try Self.preparedDocumentReplacement(replacement.draft)
        guard expected == replacement else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        return try await commitDocumentEdit(
            request: replacement.request,
            reference: replacement.draft.reference
        )
    }

    func prepareDocumentPartialUpdate(
        _ draft: WorkspaceDocumentPartialUpdateDraft
    ) async throws -> WorkspacePreparedDocumentPartialUpdate {
        try requireConnection()
        return try Self.preparedDocumentPartialUpdate(draft)
    }

    func commitDocumentPartialUpdate(
        _ update: WorkspacePreparedDocumentPartialUpdate
    ) async throws -> WorkspaceDocumentReplacementResult {
        try requireConnection()
        let expected = try Self.preparedDocumentPartialUpdate(update.draft)
        guard expected == update else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        return try await commitDocumentEdit(
            request: update.request,
            reference: update.draft.reference
        )
    }

    func prepareDocumentDeletion(
        _ draft: WorkspaceDocumentDeletionDraft
    ) async throws -> WorkspacePreparedDocumentDeletion {
        try requireConnection()
        return try Self.preparedDocumentDeletion(draft)
    }

    func commitDocumentDeletion(
        _ deletion: WorkspacePreparedDocumentDeletion
    ) async throws -> WorkspaceDocumentDeletionResult {
        try requireConnection()
        let expected = try Self.preparedDocumentDeletion(deletion.draft)
        guard expected == deletion else {
            throw WorkspaceDocumentEditingError.invalidSource
        }

        let response: ElasticsearchHTTPClient.Response
        do {
            response = try await client.perform(
                method: deletion.request.method,
                path: deletion.request.path,
                body: deletion.request.body,
                maximumResponseBytes: 1_048_576,
                preserveCompletedResponse: true
            )
        } catch ElasticsearchError.server(let status, _) where status == 409 {
            throw WorkspaceDocumentEditingError.conflict
        } catch ElasticsearchError.server(let status, _) where status == 404 {
            throw WorkspaceDocumentEditingError.documentNotFound
        }
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let result = root["result"] as? String
        else {
            throw ElasticsearchError.invalidResponse
        }
        guard result == "deleted" else {
            if result == "not_found" {
                throw WorkspaceDocumentEditingError.documentNotFound
            }
            throw ElasticsearchError.invalidResponse
        }
        await resetPaging()
        documentScores.removeAll(keepingCapacity: false)
        return WorkspaceDocumentDeletionResult(
            reference: deletion.draft.reference
        )
    }

    private func commitDocumentEdit(
        request: WorkspaceRequest,
        reference: WorkspaceDocumentReference
    ) async throws -> WorkspaceDocumentReplacementResult {
        let response: ElasticsearchHTTPClient.Response
        do {
            response = try await client.perform(
                method: request.method,
                path: request.path,
                body: request.body,
                maximumResponseBytes: 1_048_576,
                preserveCompletedResponse: true
            )
        } catch ElasticsearchError.server(let status, _) where status == 409 {
            throw WorkspaceDocumentEditingError.conflict
        }
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let sequenceNumber = Self.int64(root["_seq_no"]),
        let primaryTerm = Self.int64(root["_primary_term"])
        else {
            throw ElasticsearchError.invalidResponse
        }
        await resetPaging()
        documentScores.removeAll(keepingCapacity: false)
        return WorkspaceDocumentReplacementResult(
            reference: reference,
            version: Self.integer(root["_version"]),
            sequenceNumber: sequenceNumber,
            primaryTerm: primaryTerm
        )
    }

    func close() async {
        await resetPaging()
        connected = false
        mappingGeneration = UUID()
        supportsPITShardDocSort = false
        mappingCache.removeAll()
        documentScores.removeAll()
        await client.close()
    }

    private func mapping(for resource: String) async throws
        -> ElasticsearchMappingCatalog
    {
        if let cached = mappingCache[resource] { return cached }
        let generation = mappingGeneration
        let encoded = Self.pathComponent(resource)
        async let mappingResponse = client.perform(
            method: .get,
            path: "/\(encoded)/_mapping"
        )
        async let capsResponse = client.perform(
            method: .post,
            path: "/\(encoded)/_field_caps?fields=*",
            body: Data("{}".utf8)
        )
        let (mapping, caps) = try await (mappingResponse, capsResponse)
        let catalog = try ElasticsearchMappingCatalog.parse(
            mappingData: mapping.body,
            fieldCapsData: caps.body
        )
        try Task.checkCancellation()
        guard generation == mappingGeneration, connected else { throw CancellationError() }
        mappingCache[resource] = catalog
        return catalog
    }

    private func openPIT(resource: String) async throws -> String {
        let response = try await client.perform(
            method: .post,
            path: "/\(Self.pathComponent(resource))/_pit?keep_alive=1m"
        )
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
        let id = root["id"] as? String
        else { throw ElasticsearchError.invalidResponse }
        return id
    }

    private func resetPaging() async {
        guard let pitID = pageState?.pitID else {
            pageState = nil
            return
        }
        pageState = nil
        let body = try? JSONSerialization.data(withJSONObject: ["id": pitID])
        _ = try? await client.perform(
            method: .delete,
            path: "/_pit",
            body: body
        )
    }

    private func closePIT(_ pitID: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["id": pitID])
        _ = try? await client.perform(
            method: .delete,
            path: "/_pit",
            body: body
        )
    }

    private func makeBatch(
        hits: [[String: Any]],
        offset: Int,
        mapping: ElasticsearchMappingCatalog
    ) throws -> WorkspaceDatabaseDataBatch {
        var sources: [[String: Any]] = []
        var sourceNames = Set<String>()
        for hit in hits {
            let source = hit["_source"] as? [String: Any] ?? [:]
            sourceNames.formUnion(source.keys)
            sources.append(source)
        }
        let mappedTopLevelNames = mapping.fields
            .map(\.path)
            .filter { !$0.contains(".") }
        sourceNames.subtract(mappedTopLevelNames)
        let names = ["_id", "_index", "_score", "_routing"]
            + mappedTopLevelNames
            + sourceNames.sorted()
        let columns = names.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        var rows: [WorkspaceDatabaseDataRow] = []
        rows.reserveCapacity(hits.count)
        for (rowIndex, hit) in hits.enumerated() {
            let routing = Self.routing(from: hit)
            let reference = WorkspaceDocumentReference(
                index: hit["_index"] as? String ?? "",
                id: hit["_id"] as? String ?? "",
                routing: routing
            )
            if let score = hit["_score"] as? Double {
                documentScores[reference] = score
            }
            let source = sources[rowIndex]
            let values = names.map { name -> WorkspaceDatabaseDataCell in
                switch name {
                case "_id": return .text(reference.id)
                case "_index": return .text(reference.index)
                case "_score": return Self.cell(hit["_score"])
                case "_routing": return Self.cell(routing)
                default: return Self.cell(source[name])
                }
            }
            rows.append(
                WorkspaceDatabaseDataRow(
                    id: offset + rowIndex,
                    values: values
                )
            )
        }
        return WorkspaceDatabaseDataBatch(columns: columns, rows: rows)
    }

    private static func routing(from hit: [String: Any]) -> String? {
        if let routing = hit["_routing"] as? String, !routing.isEmpty {
            return routing
        }
        let storedRouting = (hit["fields"] as? [String: Any])?["_routing"]
        if let routing = storedRouting as? String, !routing.isEmpty {
            return routing
        }
        if let routing = (storedRouting as? [Any])?.first as? String,
           !routing.isEmpty
        {
            return routing
        }
        return nil
    }

    private func validate(
        sort: WorkspaceDatabaseDataSort,
        mapping: ElasticsearchMappingCatalog
    ) throws {
        let name: String?
        switch sort {
        case .none: name = nil
        case .ascending(let columnName), .descending(let columnName):
            name = columnName
        }
        guard let name else { return }
        if ["_id", "_index", "_score", "_routing"].contains(name) { return }
        guard let field = mapping.byPath[name],
              !field.hasTypeConflict,
              field.isAggregatable
        else { throw ElasticsearchError.mappingConflict(name) }
    }

    private func sortBody(
        _ sort: WorkspaceDatabaseDataSort,
        usesPIT: Bool
    ) -> [[String: Any]] {
        let tieBreaker = usesPIT ? "_shard_doc" : "_doc"
        return switch sort {
        case .none:
            [[tieBreaker: "asc"]]
        case .ascending(let name):
            [[name: ["order": "asc", "unmapped_type": "keyword"]], [tieBreaker: "asc"]]
        case .descending(let name):
            [[name: ["order": "desc", "unmapped_type": "keyword"]], [tieBreaker: "asc"]]
        }
    }

    private func requireConnection() throws {
        guard connected else { throw WorkspaceSessionError.notConnected }
    }

    static func isSupported(version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        if major > 7 { return true }
        return major == 7 && parts.dropFirst().first.map { $0 >= 10 } == true
    }

    static func supportsShardDocSort(version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        if major > 7 { return true }
        return major == 7 && parts.dropFirst().first.map { $0 >= 12 } == true
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed
                .subtracting(CharacterSet(charactersIn: "/?#"))
        ) ?? value
    }

    private static func queryComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlQueryAllowed
                .subtracting(CharacterSet(charactersIn: "&=+#?"))
        ) ?? value
    }

    private static func preparedDocumentReplacement(
        _ draft: WorkspaceDocumentReplacementDraft
    ) throws -> WorkspacePreparedDocumentReplacement {
        guard draft.sourceJSON.count <= maximumEditableDocumentBytes else {
            throw WorkspaceDocumentEditingError.sourceTooLarge(
                maximumEditableDocumentBytes
            )
        }
        guard let source = try? JSONSerialization.jsonObject(
            with: draft.sourceJSON
        ), source is [String: Any] else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        var path = "/\(pathComponent(draft.reference.index))/_doc/"
            + pathComponent(draft.reference.id)
            + "?if_seq_no=\(draft.sequenceNumber)"
            + "&if_primary_term=\(draft.primaryTerm)"
            + "&refresh=wait_for"
        if let routing = draft.reference.routing, !routing.isEmpty {
            path += "&routing=\(queryComponent(routing))"
        }
        return WorkspacePreparedDocumentReplacement(
            draft: draft,
            request: WorkspaceRequest(
                method: .put,
                path: path,
                body: draft.sourceJSON
            )
        )
    }

    private static func preparedDocumentCreation(
        _ draft: WorkspaceDocumentCreationDraft
    ) throws -> WorkspacePreparedDocumentCreation {
        guard !draft.targetName.isEmpty else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        guard draft.sourceJSON.count <= maximumEditableDocumentBytes else {
            throw WorkspaceDocumentEditingError.sourceTooLarge(
                maximumEditableDocumentBytes
            )
        }
        guard let source = try? JSONSerialization.jsonObject(
            with: draft.sourceJSON
        ), source is [String: Any] else {
            throw WorkspaceDocumentEditingError.invalidSource
        }

        let target = pathComponent(draft.targetName)
        let method: WorkspaceRequestMethod
        var path: String
        if let id = draft.id, !id.isEmpty {
            method = .put
            path = "/\(target)/_create/\(pathComponent(id))?refresh=wait_for"
        } else {
            method = .post
            path = "/\(target)/_doc?refresh=wait_for"
            if draft.targetKind == .dataStream {
                path += "&op_type=create"
            }
        }
        if let routing = draft.routing, !routing.isEmpty {
            path += "&routing=\(queryComponent(routing))"
        }
        return WorkspacePreparedDocumentCreation(
            draft: draft,
            request: WorkspaceRequest(
                method: method,
                path: path,
                body: draft.sourceJSON
            )
        )
    }

    private static func preparedDocumentPartialUpdate(
        _ draft: WorkspaceDocumentPartialUpdateDraft
    ) throws -> WorkspacePreparedDocumentPartialUpdate {
        guard draft.sourceJSON.count <= maximumEditableDocumentBytes,
              draft.changedFieldsJSON.count <= maximumEditableDocumentBytes
        else {
            throw WorkspaceDocumentEditingError.sourceTooLarge(
                maximumEditableDocumentBytes
            )
        }
        guard let source = try? JSONSerialization.jsonObject(
            with: draft.sourceJSON
        ), source is [String: Any],
              let changedFields = try? JSONSerialization.jsonObject(
                with: draft.changedFieldsJSON
              ) as? [String: Any],
              !changedFields.isEmpty,
              changedFields.keys.allSatisfy({
                  !readOnlyDocumentFieldNames.contains($0)
              })
        else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        let body = try JSONSerialization.data(
            withJSONObject: ["doc": changedFields],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var path = "/\(pathComponent(draft.reference.index))/_update/"
            + pathComponent(draft.reference.id)
            + "?if_seq_no=\(draft.sequenceNumber)"
            + "&if_primary_term=\(draft.primaryTerm)"
            + "&refresh=wait_for"
        if let routing = draft.reference.routing, !routing.isEmpty {
            path += "&routing=\(queryComponent(routing))"
        }
        return WorkspacePreparedDocumentPartialUpdate(
            draft: draft,
            request: WorkspaceRequest(method: .post, path: path, body: body)
        )
    }

    private static func preparedDocumentDeletion(
        _ draft: WorkspaceDocumentDeletionDraft
    ) throws -> WorkspacePreparedDocumentDeletion {
        guard draft.sequenceNumber >= 0, draft.primaryTerm > 0 else {
            throw WorkspaceDocumentEditingError.missingConcurrencyMetadata
        }
        var path = "/\(pathComponent(draft.reference.index))/_doc/"
            + pathComponent(draft.reference.id)
            + "?if_seq_no=\(draft.sequenceNumber)"
            + "&if_primary_term=\(draft.primaryTerm)"
            + "&refresh=wait_for"
        if let routing = draft.reference.routing, !routing.isEmpty {
            path += "&routing=\(queryComponent(routing))"
        }
        return WorkspacePreparedDocumentDeletion(
            draft: draft,
            request: WorkspaceRequest(method: .delete, path: path)
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func names(in value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap {
            if let name = $0 as? String { return name }
            return ($0 as? [String: Any])?["name"] as? String
        }
    }

    private static func mergedSummary(
        names: [String],
        summaries: [String: WorkspaceDatabaseObjectSummary]
    ) -> WorkspaceDatabaseObjectSummary? {
        let values = names.compactMap { summaries[$0] }
        guard !values.isEmpty else { return nil }
        return WorkspaceDatabaseObjectSummary(
            documentCount: values.compactMap(\.documentCount).reduce(0, +),
            storageByteCount: values.compactMap(\.storageByteCount).reduce(0, +),
            health: values.compactMap(\.health).sorted().first
        )
    }

    private static func cell(_ value: Any?) -> WorkspaceDatabaseDataCell {
        guard let value, !(value is NSNull) else { return .null }
        if value is [Any] || value is [String: Any],
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys, .withoutEscapingSlashes]
           ),
           let text = String(data: data, encoding: .utf8)
        {
            return .text(text)
        }
        // NSNumber also bridges numeric 0/1 to Bool; only JSON booleans have CFBoolean identity.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .text(number.boolValue ? "true" : "false")
        }
        return .text(String(describing: value))
    }
}
