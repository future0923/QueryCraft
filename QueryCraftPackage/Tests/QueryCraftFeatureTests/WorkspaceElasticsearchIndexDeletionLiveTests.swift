import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.timeLimit(.minutes(3)))
struct WorkspaceElasticsearchIndexDeletionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_ES_LIVE_TESTS"] == "1"), arguments: [19280, 19290])
    @MainActor func exactDeletionAndAliasStreamRejection(port: Int) async throws {
        let (model, session) = await indexDeletionFixture(port: port)
        model.safetyLock.disable()
        let name = "qc_index_delete_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let alias = name + "_alias"
        let stream = name + "_stream"
        let template = name + "_template"
        do {
            let absent = try await session.executeRequest(.init(method: .head, path: "/" + name))
            #expect(absent.statusCode == 404)
            let created = try await session.executeRequest(.init(method: .put, path: "/" + name,
                body: Data("{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0},\"aliases\":{\"\(alias)\":{}}}".utf8)), policy: .writesAllowed)
            #expect(created.statusCode == 200)
            let templateResult = try await session.executeRequest(.init(method: .put, path: "/_index_template/" + template,
                body: Data("{\"index_patterns\":[\"\(stream)\"],\"priority\":500,\"data_stream\":{},\"template\":{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0}}}".utf8)), policy: .writesAllowed)
            #expect(templateResult.statusCode == 200)
            #expect(try await session.executeRequest(.init(method: .put, path: "/_data_stream/" + stream), policy: .writesAllowed).statusCode == 200)
            // Even a stale/incorrect sidebar kind cannot turn an Alias or stream
            // into a deletable ordinary index after server-side resolution.
            for other in [alias, stream] {
                let prepared = try await WorkspaceIndexDeletionWorker().prepare(indexSelection(other))
                await #expect(throws: WorkspaceIndexDeletionNotSentError.self) { try await model.deleteElasticsearchIndex(prepared) }
                #expect(try await session.executeRequest(.init(method: .head, path: "/" + other)).statusCode == 200)
            }
            #expect(try await session.executeRequest(.init(method: .put, path: "/\(name)/_doc/one",
                body: Data(#"{"name":"delete fixture","count":1}"#.utf8)), policy: .writesAllowed).statusCode == 201)
            let editor = WorkspaceElasticsearchIndexDeletionEditor(selection: indexSelection(name))
            await editor.prepare()
            editor.confirmation = name
            await editor.submit(execute: model.deleteElasticsearchIndex)
            #expect(editor.isAbsent && !editor.mustVerify)
            #expect(try await session.executeRequest(.init(method: .head, path: "/" + name)).statusCode == 404)
            #expect(try await session.executeRequest(.init(method: .head, path: "/" + stream)).statusCode == 200)
            let again = WorkspaceElasticsearchIndexDeletionEditor(selection: indexSelection(name))
            await again.prepare()
            again.confirmation = name
            await again.submit(execute: model.deleteElasticsearchIndex)
            #expect(again.isAbsent && !again.mustVerify)
            await cleanup(session, name: name, stream: stream, template: template)
            await model.disconnect()
        } catch {
            await cleanup(session, name: name, stream: stream, template: template)
            await model.disconnect()
            throw error
        }
    }

    private func cleanup(_ session: IndexDeletionTestSession, name: String, stream: String, template: String) async {
        for path in ["/_data_stream/" + stream, "/_index_template/" + template, "/" + name] {
            _ = try? await session.executeRequest(.init(method: .delete, path: path), policy: .writesAllowed)
        }
    }
}
