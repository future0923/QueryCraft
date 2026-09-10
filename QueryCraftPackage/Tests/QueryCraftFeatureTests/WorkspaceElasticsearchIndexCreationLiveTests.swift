import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.timeLimit(.minutes(2)))
struct WorkspaceElasticsearchIndexCreationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_ES_LIVE_TESTS"] == "1"),
          arguments: [19280, 19290])
    @MainActor func createsExactPreparedRequestAndRejectsDuplicate(port: Int) async throws {
        // Opt-in only, restricted to the user's two disposable local clusters.
        let name = "qc_index_creation_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let server = IndexCreationTestServer(port: port)
        let editor = WorkspaceElasticsearchIndexCreationEditor()
        editor.input = .init(name: name, shards: "1", replicas: "0", mapping:
            #"{"_meta":{"precise":18446744073709551615},"properties":{"name":{"type":"keyword"},"count":{"type":"integer"}}}"#)
        await editor.validate()
        let prepared = try #require(editor.currentPrepared)
        do {
            let absent = try await server.send(prepared.verificationRequest)
            #expect(absent.statusCode == 404)
            await editor.submit(prepared) { try await server.send($0) }
            #expect(editor.wasCreated && editor.indexExists)
            try await server.checkMappingAndSettings(name: name)
            let duplicate = WorkspaceElasticsearchIndexCreationEditor()
            duplicate.input = editor.input
            await duplicate.validate()
            await duplicate.submit(try #require(duplicate.currentPrepared)) { try await server.send($0) }
            #expect(!duplicate.indexExists && duplicate.canSubmit && !duplicate.mustVerify)
            #expect(duplicate.responseText.contains("resource_already_exists_exception"))
            #expect(duplicate.input == editor.input)
            let removed = try await server.send(.init(method: .delete, path: prepared.request.path))
            #expect(removed.statusCode == 200)
            let missing = try await server.send(prepared.verificationRequest)
            #expect(missing.statusCode == 404)
        } catch {
            _ = try? await server.send(.init(method: .delete, path: prepared.request.path))
            throw error
        }
    }
}

private actor IndexCreationTestServer {
    let port: Int
    init(port: Int) { self.port = port }

    func send(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)" + request.path))
        var transport = URLRequest(url: url, timeoutInterval: 40)
        transport.httpMethod = request.method.rawValue
        transport.httpBody = request.body
        transport.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.data(for: transport)
        let http = try #require(response as? HTTPURLResponse)
        return .init(statusCode: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: body)
    }

    func checkMappingAndSettings(name: String) async throws {
        let response = try await send(.init(method: .get, path: "/" + name))
        #expect(response.statusCode == 200)
        let root = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let index = try #require(root[name] as? [String: Any])
        let mapping = try #require(index["mappings"] as? [String: Any])
        let properties = try #require(mapping["properties"] as? [String: [String: Any]])
        #expect(properties["name"]?["type"] as? String == "keyword")
        #expect(properties["count"]?["type"] as? String == "integer")
        #expect(String(decoding: response.body, as: UTF8.self).contains("18446744073709551615"))
        let settings = try #require(index["settings"] as? [String: [String: Any]])
        #expect(settings["index"]?["number_of_shards"] as? String == "1")
        #expect(settings["index"]?["number_of_replicas"] as? String == "0")
    }
}
