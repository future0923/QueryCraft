import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch document editing")
struct ElasticsearchDocumentEditingTests {
    @Test("Creates an explicitly identified document without overwrite")
    func explicitCreationRequest() async throws {
        let host = "document-create-explicit.local"
        let observedMethod = Mutex<String?>(nil)
        let observedBody = Mutex<Data?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return Self.rootResponse(request)
            case ("PUT", "/logs write/_create/a/b"):
                observedMethod.withLock { $0 = request.httpMethod }
                observedBody.withLock { $0 = Self.requestBody(request) }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"_index":"logs-000042","_id":"a/b","_version":1,"_seq_no":7,"_primary_term":2,"result":"created"}"#
                )
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let source = Data(#"{"name":"new"}"#.utf8)
        let draft = WorkspaceDocumentCreationDraft(
            targetName: "logs write",
            targetKind: .alias,
            id: "a/b",
            routing: "tenant + 1",
            sourceJSON: source
        )

        let prepared = try await session.prepareDocumentCreation(draft)
        #expect(prepared.request.method == .put)
        #expect(prepared.request.body == source)
        #expect(prepared.request.path.contains("/logs%20write/_create/a%2Fb?"))
        #expect(prepared.request.path.contains("refresh=wait_for"))
        #expect(prepared.request.path.contains("routing=tenant%20%2B%201"))

        let result = try await session.commitDocumentCreation(prepared)
        #expect(result.reference.index == "logs-000042")
        #expect(result.reference.id == "a/b")
        #expect(result.reference.routing == "tenant + 1")
        #expect(result.version == 1)
        #expect(result.sequenceNumber == 7)
        #expect(result.primaryTerm == 2)
        #expect(observedMethod.withLock { $0 } == "PUT")
        #expect(observedBody.withLock { $0 } == source)
        await session.close()
    }

    @Test("Uses create-only auto identity for a data stream")
    func dataStreamAutoIdentityCreationRequest() async throws {
        let host = "document-create-data-stream.local"
        let observedURL = Mutex<URL?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            observedURL.withLock { $0 = request.url }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                json: #"{"_index":".ds-logs-2026.09.04-000001","_id":"generated-1","_version":1,"_seq_no":1,"_primary_term":1,"result":"created"}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let source = Data(#"{"@timestamp":"2026-09-04T00:00:00Z"}"#.utf8)

        let prepared = try await session.prepareDocumentCreation(
            WorkspaceDocumentCreationDraft(
                targetName: "logs-stream",
                targetKind: .dataStream,
                sourceJSON: source
            )
        )
        #expect(prepared.request.method == .post)
        #expect(prepared.request.path == "/logs-stream/_doc?refresh=wait_for&op_type=create")
        let result = try await session.commitDocumentCreation(prepared)

        #expect(result.reference.id == "generated-1")
        #expect(observedURL.withLock { $0 }?.path == "/logs-stream/_doc")
        #expect(observedURL.withLock { $0 }?.query?.contains("op_type=create") == true)
        await session.close()
    }

    @Test("Rejects changed creation requests and existing explicit identities")
    func creationRequestIntegrityAndConflict() async throws {
        let host = "document-create-conflict.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                status: 409,
                json: #"{"error":{"type":"version_conflict_engine_exception","reason":"already exists"},"status":409}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let draft = WorkspaceDocumentCreationDraft(
            targetName: "logs",
            targetKind: .index,
            id: "existing",
            sourceJSON: Data("{}".utf8)
        )
        let prepared = try await session.prepareDocumentCreation(draft)
        let changed = WorkspacePreparedDocumentCreation(
            draft: draft,
            request: WorkspaceRequest(
                method: .post,
                path: "/other/_doc",
                body: draft.sourceJSON
            )
        )

        await #expect(throws: WorkspaceDocumentEditingError.invalidSource) {
            _ = try await session.commitDocumentCreation(changed)
        }
        await #expect(throws: WorkspaceDocumentEditingError.documentAlreadyExists) {
            _ = try await session.commitDocumentCreation(prepared)
        }
        await session.close()
    }

    @Test("Previews and commits the exact guarded replacement request")
    func replacementRequest() async throws {
        let host = "document-edit.local"
        let observedBody = Mutex<Data?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return Self.rootResponse(request)
            case ("PUT", "/logs 2026/_doc/a/b"):
                observedBody.withLock { $0 = Self.requestBody(request) }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"_version":8,"_seq_no":42,"_primary_term":3}"#
                )
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let source = Data(#"{"count":9007199254740993,"name":"A"}"#.utf8)
        let draft = WorkspaceDocumentReplacementDraft(
            reference: WorkspaceDocumentReference(
                index: "logs 2026",
                id: "a/b",
                routing: "tenant + 1"
            ),
            sequenceNumber: 41,
            primaryTerm: 3,
            sourceJSON: source
        )

        let prepared = try await session.prepareDocumentReplacement(draft)
        #expect(prepared.request.method == .put)
        #expect(prepared.request.body == source)
        #expect(prepared.request.path.contains("/logs%202026/_doc/a%2Fb?"))
        #expect(prepared.request.path.contains("if_seq_no=41"))
        #expect(prepared.request.path.contains("if_primary_term=3"))
        #expect(prepared.request.path.contains("refresh=wait_for"))
        #expect(prepared.request.path.contains("routing=tenant%20%2B%201"))

        let result = try await session.commitDocumentReplacement(prepared)
        #expect(result.version == 8)
        #expect(result.sequenceNumber == 42)
        #expect(result.primaryTerm == 3)
        #expect(observedBody.withLock { $0 } == source)
        await session.close()
    }

    @Test("Previews and commits the exact guarded partial update request")
    func partialUpdateRequest() async throws {
        let host = "document-partial-edit.local"
        let observedMethod = Mutex<String?>(nil)
        let observedBody = Mutex<Data?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return Self.rootResponse(request)
            case ("POST", "/logs 2026/_update/a/b"):
                observedMethod.withLock { $0 = request.httpMethod }
                observedBody.withLock { $0 = Self.requestBody(request) }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"_version":8,"_seq_no":42,"_primary_term":3}"#
                )
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let draft = WorkspaceDocumentPartialUpdateDraft(
            reference: WorkspaceDocumentReference(
                index: "logs 2026",
                id: "a/b",
                routing: "tenant + 1"
            ),
            sequenceNumber: 41,
            primaryTerm: 3,
            sourceJSON: Data(
                #"{"name":"new","untouched":true}"#.utf8
            ),
            changedFieldsJSON: Data(#"{"name":"new"}"#.utf8)
        )

        let prepared = try await session.prepareDocumentPartialUpdate(draft)
        #expect(prepared.request.method == .post)
        #expect(prepared.request.path.contains("/logs%202026/_update/a%2Fb?"))
        #expect(prepared.request.path.contains("if_seq_no=41"))
        #expect(prepared.request.path.contains("if_primary_term=3"))
        #expect(prepared.request.path.contains("refresh=wait_for"))
        #expect(prepared.request.path.contains("routing=tenant%20%2B%201"))
        let body = try #require(prepared.request.body)
        let bodyObject = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let doc = try #require(bodyObject["doc"] as? [String: Any])
        #expect(doc["name"] as? String == "new")
        #expect(doc["untouched"] == nil)

        let result = try await session.commitDocumentPartialUpdate(prepared)
        #expect(result.version == 8)
        #expect(result.sequenceNumber == 42)
        #expect(result.primaryTerm == 3)
        #expect(observedMethod.withLock { $0 } == "POST")
        #expect(observedBody.withLock { $0 } == prepared.request.body)
        await session.close()
    }

    @Test("Rejects empty or metadata partial updates")
    func invalidPartialUpdates() async throws {
        let host = "document-invalid-partial.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            Self.rootResponse(request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let reference = WorkspaceDocumentReference(index: "logs", id: "1")

        for changedFields in [Data("{}".utf8), Data(#"{"_id":"2"}"#.utf8)] {
            await #expect(throws: WorkspaceDocumentEditingError.invalidSource) {
                _ = try await session.prepareDocumentPartialUpdate(
                    WorkspaceDocumentPartialUpdateDraft(
                        reference: reference,
                        sequenceNumber: 1,
                        primaryTerm: 1,
                        sourceJSON: Data(#"{"name":"new"}"#.utf8),
                        changedFieldsJSON: changedFields
                    )
                )
            }
        }
        await session.close()
    }

    @Test("Previews and commits the exact guarded deletion request")
    func deletionRequest() async throws {
        let host = "document-delete.local"
        let observedMethod = Mutex<String?>(nil)
        let observedBody = Mutex<Data?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return Self.rootResponse(request)
            case ("DELETE", "/logs 2026/_doc/a/b"):
                observedMethod.withLock { $0 = request.httpMethod }
                observedBody.withLock { $0 = request.httpBody }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"_version":8,"_seq_no":42,"_primary_term":3,"result":"deleted"}"#
                )
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let draft = WorkspaceDocumentDeletionDraft(
            reference: WorkspaceDocumentReference(
                index: "logs 2026",
                id: "a/b",
                routing: "tenant + 1"
            ),
            sequenceNumber: 41,
            primaryTerm: 3
        )

        let prepared = try await session.prepareDocumentDeletion(draft)
        #expect(prepared.request.method == .delete)
        #expect(prepared.request.body == nil)
        #expect(prepared.request.path.contains("/logs%202026/_doc/a%2Fb?"))
        #expect(prepared.request.path.contains("if_seq_no=41"))
        #expect(prepared.request.path.contains("if_primary_term=3"))
        #expect(prepared.request.path.contains("refresh=wait_for"))
        #expect(prepared.request.path.contains("routing=tenant%20%2B%201"))

        let result = try await session.commitDocumentDeletion(prepared)
        #expect(result.reference == draft.reference)
        #expect(observedMethod.withLock { $0 } == "DELETE")
        #expect(observedBody.withLock { $0 } == nil)
        await session.close()
    }

    @Test("Rejects changed prepared deletion requests")
    func changedDeletionRequest() async throws {
        let host = "document-delete-changed.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            Self.rootResponse(request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let draft = WorkspaceDocumentDeletionDraft(
            reference: WorkspaceDocumentReference(index: "logs", id: "1"),
            sequenceNumber: 1,
            primaryTerm: 1
        )
        let prepared = try await session.prepareDocumentDeletion(draft)
        let changed = WorkspacePreparedDocumentDeletion(
            draft: draft,
            request: WorkspaceRequest(method: .delete, path: "/other/_doc/1")
        )

        await #expect(throws: WorkspaceDocumentEditingError.invalidSource) {
            _ = try await session.commitDocumentDeletion(changed)
        }
        #expect(prepared.request.path != changed.request.path)
        await session.close()
    }

    @Test("Maps version conflicts without changing the prepared draft")
    func conflict() async throws {
        let host = "document-conflict.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                status: 409,
                json: #"{"error":{"type":"version_conflict_engine_exception","reason":"conflict"},"status":409}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let prepared = try await session.prepareDocumentReplacement(
            WorkspaceDocumentReplacementDraft(
                reference: WorkspaceDocumentReference(index: "logs", id: "1"),
                sequenceNumber: 1,
                primaryTerm: 1,
                sourceJSON: Data(#"{"name":"draft"}"#.utf8)
            )
        )

        await #expect(throws: WorkspaceDocumentEditingError.conflict) {
            _ = try await session.commitDocumentReplacement(prepared)
        }
        #expect(prepared.request.body == Data(#"{"name":"draft"}"#.utf8))
        await session.close()
    }

    @Test("Maps missing documents during deletion")
    func deletionNotFound() async throws {
        let host = "document-delete-missing.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                status: 404,
                json: #"{"_index":"logs","_id":"1","result":"not_found"}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let prepared = try await session.prepareDocumentDeletion(
            WorkspaceDocumentDeletionDraft(
                reference: WorkspaceDocumentReference(index: "logs", id: "1"),
                sequenceNumber: 1,
                primaryTerm: 1
            )
        )

        await #expect(throws: WorkspaceDocumentEditingError.documentNotFound) {
            _ = try await session.commitDocumentDeletion(prepared)
        }
        await session.close()
    }

    @Test("Maps guarded deletion version conflicts")
    func deletionConflict() async throws {
        let host = "document-delete-conflict.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                status: 409,
                json: #"{"error":{"type":"version_conflict_engine_exception","reason":"conflict"},"status":409}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let prepared = try await session.prepareDocumentDeletion(
            WorkspaceDocumentDeletionDraft(
                reference: WorkspaceDocumentReference(index: "logs", id: "1"),
                sequenceNumber: 1,
                primaryTerm: 1
            )
        )

        await #expect(throws: WorkspaceDocumentEditingError.conflict) {
            _ = try await session.commitDocumentDeletion(prepared)
        }
        #expect(prepared.request.method == .delete)
        #expect(prepared.request.body == nil)
        await session.close()
    }

    @Test("Fetches concurrency metadata and immutable routing")
    func fetchMetadata() async throws {
        let host = "document-fetch.local"
        let observedURL = Mutex<URL?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.rootResponse(request) }
            observedURL.withLock { $0 = request.url }
            return ElasticsearchURLProtocolStub.response(
                for: request,
                json: #"{"_index":"logs","_id":"1","_version":7,"_seq_no":31,"_primary_term":2,"_routing":"tenant-a","_source":{"ok":true}}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()

        let snapshot = try await session.fetchDocument(
            WorkspaceDocumentReference(
                index: "logs",
                id: "1",
                routing: "tenant-a"
            ),
            maximumByteCount: 1_024
        )
        #expect(snapshot.sequenceNumber == 31)
        #expect(snapshot.primaryTerm == 2)
        #expect(snapshot.reference.routing == "tenant-a")
        #expect(observedURL.withLock { $0 }?.query == "routing=tenant-a")
        await session.close()
    }

    private func makeSession(host: String) throws -> ElasticsearchWorkspaceSession {
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .elasticsearch,
            databaseProduct: .elasticsearch,
            host: host,
            port: 9_200,
            authentication: .none,
            database: nil,
            tlsMode: .disabled
        )
        return try ElasticsearchWorkspaceSession(
            configuration: ElasticsearchConnectionConfiguration(configuration),
            protocolClasses: [ElasticsearchURLProtocolStub.self]
        )
    }

    private static func rootResponse(
        _ request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        ElasticsearchURLProtocolStub.response(
            for: request,
            headers: [
                "Content-Type": "application/json",
                "X-Elastic-Product": "Elasticsearch",
            ],
            json: #"{"version":{"number":"8.18.0"},"tagline":"You Know, for Search"}"#
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
