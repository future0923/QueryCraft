import Foundation
import Synchronization
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileElasticsearchStateTests {
    private func session(_ host: String) throws -> ElasticsearchWorkspaceSession {
        try .init(configuration: .init(host: host, port: 9200, authentication: .none, tlsMode: .disabled), protocolClasses: [ElasticsearchURLProtocolStub.self], maximumResponseBytes: 1_048_576)
    }
    nonisolated private static func root(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        ElasticsearchURLProtocolStub.response(for: request, headers: ["Content-Type":"application/json", "X-Elastic-Product":"Elasticsearch"], json: #"{"version":{"number":"8.18.0"},"tagline":"You Know, for Search"}"#)
    }
    @Test func unknownIndexWriteRetainsFenceWhenVerificationDeniedAndNeverReplays() async throws {
        let host = "mobile-unknown-index.local", writes = Mutex(0), allowed = Mutex(false)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            if request.httpMethod == "PUT" { writes.withLock { $0 += 1 }; throw URLError(.networkConnectionLost) }
            return ElasticsearchURLProtocolStub.response(for: request, status: allowed.withLock { $0 } ? 200 : 403)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host))
        let action = MobileElasticsearchAction(owner: model, kind: .createIndex, object: nil, reference: nil)
        await action.reload()?.value; action.name = "mobile-index"; action.replicas = "0"; await action.prepare()?.value
        #expect(action.preview != nil); model.safetyLock.disable(); await action.submit()?.value
        #expect(action.needsVerification); #expect(action.canSubmit == false); #expect(writes.withLock { $0 } == 1)
        await action.verify()?.value; #expect(!action.verified); #expect(action.needsVerification)
        await action.submit()?.value; #expect(writes.withLock { $0 } == 1)
        allowed.withLock { $0 = true }; await action.verify()?.value; #expect(action.verified); #expect(action.needsVerification)
        action.finishVerification(); #expect(!action.needsVerification); #expect(action.completed)
        await model.session?.close()
    }
    @Test func confirmationChangesInvalidateAndBackgroundCannotSend() async throws {
        let host = "mobile-stale-preview.local", writes = Mutex(0)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            writes.withLock { $0 += 1 }; return ElasticsearchURLProtocolStub.response(for: request, json: #"{"acknowledged":true}"#)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host))
        let action = MobileElasticsearchAction(owner: model, kind: .createIndex, object: nil, reference: nil)
        await action.reload()?.value; action.name = "before"; await action.prepare()?.value; #expect(action.preview != nil)
        action.name = "after"; model.safetyLock.disable(); #expect(action.preview == nil); await action.submit()?.value; #expect(writes.withLock { $0 } == 0)
        await action.prepare()?.value; action.setBackgrounded(true); #expect(action.preview == nil); await action.submit()?.value; #expect(writes.withLock { $0 } == 0)
        await model.session?.close()
    }
    @Test func failedRefreshPreservesCatalogAndBackgroundCancelsInFlightRead() async throws {
        let host = "mobile-stable-read.local", failing = Mutex(false)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            if failing.withLock({ $0 }) { return ElasticsearchURLProtocolStub.response(for: request, status: 403) }
            if request.url?.path.contains("_cat") == true { return ElasticsearchURLProtocolStub.response(for: request, json: #"[{"index":"logs","docs.count":"1","store.size":"20","health":"green"}]"#) }
            return ElasticsearchURLProtocolStub.response(for: request, json: #"{"indices":[{"name":"logs"}],"aliases":[],"data_streams":[]}"#)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host))
        await model.loadCatalog()?.value; #expect(model.catalog?.first?.name == "logs")
        failing.withLock { $0 = true }; await model.loadCatalog()?.value
        #expect(model.catalog?.first?.name == "logs"); #expect(model.catalogError != nil); #expect(!model.isLoadingCatalog)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        ElasticsearchURLProtocolStub.install(for: host, finishesLoading: false) { request in
            continuation.yield(()); return ElasticsearchURLProtocolStub.response(for: request)
        }
        let pending = model.loadCatalog(); var iterator = events.makeAsyncIterator(); _ = await iterator.next()
        model.setBackgrounded(true); await pending?.value
        #expect(model.catalog?.first?.name == "logs"); #expect(!model.isLoadingCatalog); #expect(model.loadCatalog() == nil)
        continuation.finish(); await model.session?.close()
    }
    @Test func consoleUncertainWriteAndDeniedVerificationKeepFence() async throws {
        let host = "mobile-console-unknown.local", writes = Mutex(0), allowed = Mutex(false)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            if request.httpMethod == "PUT" { writes.withLock { $0 += 1 }; return ElasticsearchURLProtocolStub.response(for: request, status: 503) }
            return ElasticsearchURLProtocolStub.response(for: request, status: allowed.withLock { $0 } ? 200 : 403)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host)), console: MobileElasticsearchConsole
        console = model.console; model.safetyLock.disable(); console.source = "PUT /logs/_create/a\n{\"name\":\"one\"}"
        await console.prepare()?.value; await console.run()?.value
        #expect(console.needsVerification); #expect(writes.withLock { $0 } == 1)
        await console.verify()?.value; #expect(!console.verified); #expect(console.needsVerification)
        allowed.withLock { $0 = true }; await console.verify()?.value; #expect(console.verified); console.finishVerification(); #expect(!console.needsVerification)
        #expect(writes.withLock { $0 } == 1); await model.session?.close()
    }
    @Test func requestCompletionSharesDesktopEndpointsAndSafePathReplacement() {
        let items = WorkspaceElasticsearchRequestCompletion.suggestions(source: "GET /logs/_se", cursor: 13, resources: [.init(name: "logs", kind: .elasticsearchIndex)])
        #expect(items.contains { $0.insertionText == "/logs/_search" })
        let methods = WorkspaceElasticsearchRequestCompletion.suggestions(source: "PO", cursor: 2, resources: [])
        #expect(methods.contains { $0.insertionText == "POST " })
    }
    @Test func partialOrTimedOutPagesCannotPublishASuccessfulEmptyState() async throws {
        let host = "mobile-partial-page.local", fail = Mutex(false)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            let path = request.url?.path ?? ""
            if path == "/" { return Self.root(request) }
            let body: String
            if path.contains("_resolve") { body = #"{"indices":[{"name":"logs"}],"aliases":[],"data_streams":[]}"# }
            else if path.contains("_mapping") { body = #"{"logs":{"mappings":{"properties":{"name":{"type":"keyword"}}}}}"# }
            else if path.contains("_field_caps") { body = #"{"fields":{"name":{"keyword":{"type":"keyword","searchable":true,"aggregatable":true}}}}"# }
            else if path.contains("_count") { body = #"{"count":0}"# }
            else if path.hasSuffix("_pit"), request.httpMethod == "POST" { return ElasticsearchURLProtocolStub.response(for: request, status: 403) }
            else { body = fail.withLock { $0 } ? #"{"timed_out":true,"_shards":{"failed":1},"hits":{"hits":[]}}"# : #"{"timed_out":false,"_shards":{"failed":0},"hits":{"hits":[]}}"# }
            return ElasticsearchURLProtocolStub.response(for: request, json: body)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host))
        model.select(.init(name: "logs", kind: .elasticsearchIndex)); await model.loadPage(fresh: true)?.value
        let revision = try #require(model.page?.revision); #expect(model.page?.rowCount == 0); #expect(model.pageError == nil)
        fail.withLock { $0 = true }; await model.loadPage(fresh: true)?.value
        #expect(model.page?.revision == revision); #expect(model.pageError != nil); #expect(!model.isLoadingPage)
        fail.withLock { $0 = false }; await model.loadPage(fresh: true)?.value; #expect(model.pageError == nil)
        await model.session?.close()
    }

    @Test func responseDiagnosticsNavigateOnlyTheUnchangedRequestSource() async throws {
        let host = "mobile-diagnostic.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            return ElasticsearchURLProtocolStub.response(for: request, status: 400, json: #"{"error":{"type":"parsing_exception","reason":"unknown query","line":1,"col":12},"status":400}"#)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: 9200), password: nil, session: try session(host))
        model.console.source = "GET /logs/_search\n{\"query\":{\"bad\":{}}}"
        await model.console.prepare()?.value; await model.console.run()?.value
        let diagnostic = try #require(model.console.currentResult?.details.diagnostics.first { $0.documentRange != nil })
        #expect(model.console.canLocate(diagnostic)); model.console.locate(diagnostic)
        #expect(model.console.selection == diagnostic.documentRange)
        model.console.source += "\n"; #expect(!model.console.canLocate(diagnostic))
        await model.session?.close()
    }

    @Test func backgroundCompletionWorkDrainsWithoutRetainingOrDereferencingReleasedWorkspace() async {
        var workspace: MobileElasticsearchWorkspace? = .init(profile: MobileElasticsearchTests.profile(port: 1), password: nil)
        weak var released = workspace
        workspace?.console.source = "GET /_cluster/health"
        workspace?.setBackgrounded(true)
        workspace?.console.source = "POST /logs/_search\n{\"query\":{\"match_all\":{}}}"
        let console = workspace?.console
        workspace = nil
        await console?.waitForReadCancellation()
        #expect(released == nil)
    }

    @Test func templateSearchSharesNameAndPatternFuzzyMatching() {
        let template = WorkspaceElasticsearchIndexTemplateSnapshot(name: "production-events", source: "{}", canonicalBody: Data("{}".utf8), indexPatterns: ["audit-user-*"], priority: 100, isDataStream: true)
        #expect(template.matchesSearch("pre")); #expect(template.matchesSearch("au")); #expect(template.matchesSearch("")); #expect(!template.matchesSearch("impossible-xyz"))
    }

}
