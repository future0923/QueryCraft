import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

enum MobileFixtureEndpoint {
    static var host: String { ProcessInfo.processInfo.environment["PROOF_SERVER_HOST"] ?? "127.0.0.1" }
}

@MainActor struct MobileDriverSupportTests {
    static func profile(_ driver: MobileDriver = .redis) -> MobileConnectionProfile {
        .init(id: UUID(), name: driver.title, host: "127.0.0.1", port: driver.port, username: "", database: "0", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: driver)
    }
    @Test func oldLibraryRemainsMySQL() throws {
        let original = Self.profile(.mysql)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "driver"); json.removeValue(forKey: "authentication")
        let decoded = try JSONDecoder().decode(MobileConnectionProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.driver == .mysql); #expect(decoded.id == original.id)
        #expect(decoded.authentication == .usernamePassword)
    }
    @Test func driverDefaultsAndRedisRestrictions() throws {
        let draft = MobileConnectionDraft(); draft.name = "test"; draft.driver = .redis
        #expect(draft.port == "6379"); #expect(draft.username.isEmpty); #expect(draft.tlsMode == .disabled)
        #expect(try draft.profile().driver == .redis)
        draft.tlsMode = .required; #expect(throws: MobileQueryError.self) { try draft.profile() }
        draft.tlsMode = .disabled; draft.database = "-1"; #expect(throws: MobileQueryError.self) { try draft.profile() }
        draft.driver = .doris; #expect(draft.port == "9030"); #expect(draft.username == "root")
        draft.driver = .elasticsearch; draft.authentication = .apiKey; draft.tlsMode = .verifyIdentity
        #expect(try draft.profile().authentication == .apiKey)
    }
    @Test func dorisDoesNotExposeMySQLMutationOrTransactions() {
        let workspace = MobileDatabaseWorkspace(profile: Self.profile(.doris), password: nil, service: MobileMySQLService())
        #expect(workspace.browser.supportsEditing == false)
        #expect(workspace.browser.schema == nil)
        #expect(workspace.query.supportsTransactions == false)
        #expect(workspace.query.allowsDataMutation() == false)
        #expect(workspace.query.allowsSQLExecution())
    }
    @Test func exportUsesRealSQLDialectAndNonSQLPagesRejectSQL() throws {
        var snapshot = MobileDataExportSnapshot(data: .init(columns: ["name"], rows: [["雪\n"]]), name: "sample", scopeDescription: "当前页")
        snapshot.sqlDialect = .doris
        var options = WorkspaceDataExportPreferences().options(for: .sql); options.sqlTableName = "sample"
        #expect(try snapshot.request(options: options).options.sqlDialect == .doris)
        snapshot.sqlDialect = nil
        #expect(throws: WorkspaceDataExportError.self) { try snapshot.request(options: options) }
        let model = MobileDataExportModel(snapshot: snapshot); model.format = .sql
        #expect(!model.canPrepare)
    }
    @Test func lateCatalogCannotReplaceNewDatabase() async {
        let service = ResourceTestService()
        let model = MobileResourceModel(profile: Self.profile(), password: nil, service: service)
        await model.load()?.value; await model.loadCatalog()?.value
        await service.holdNextCatalog()
        let old = model.loadCatalog(); await service.waitUntilHeld()
        model.selectScope("1")
        #expect(model.catalog == nil); #expect(model.details == nil)
        await model.loadCatalog()?.value
        #expect(model.catalog?.first?.name == "new_scope")
        await service.release(); await old?.value
        #expect(model.scope == "1"); #expect(model.catalog?.first?.name == "new_scope")
    }
    @Test func dorisMetadataDoesNotBindADeletedDefaultDatabase() async throws {
        let executor = DorisMetadataTestExecutor(), service = MobileDorisService(executor: executor)
        let configuration = MobileSQLConfiguration(host: "127.0.0.1", port: 9030, username: "root", password: nil, database: "deleted_database", tlsMode: .disabled)
        let catalog = try await service.objects(configuration: configuration, database: "current", search: "", kind: .table)
        let object = try #require(catalog.objects.first)
        #expect(try await service.columns(configuration: configuration, object: object).first?.comment == "real comment")
        #expect(await executor.usedOnlyCatalogConnections())
    }
    @Test func sharedScanCodecKeepsEmptyNonterminalPages() throws {
        let reply = RedisReplyValue.array([.bulkString("42"), .array([])])
        let page = try RedisScanCodec.page(reply, databaseIndex: 2)
        #expect(page.keys.isEmpty); #expect(page.nextCursor == 42)
        #expect(RedisScanCodec.arguments(cursor: 42, pattern: "a*", count: 100) == ["SCAN", "42", "MATCH", "a*", "COUNT", "100"])
        #expect(throws: RedisWorkspaceError.self) { try RedisScanCodec.page(.null, databaseIndex: 0) }
    }
    @Test func sharedElasticsearchIdentityAndPathEncoding() throws {
        let data = Data(#"{"version":{"number":"8.12.0"},"tagline":"You Know, for Search"}"#.utf8)
        #expect(try ElasticsearchServerIdentity.version(body: data, headers: [:]) == "8.12.0")
        #expect(!ElasticsearchServerIdentity.isSupported(version: "7.9.9"))
        #expect(MobileResourceService.pathComponent("a/b?雪#%*") == "a%2Fb%3F%E9%9B%AA%23%25%2A")
        #expect(throws: ElasticsearchError.self) { try ElasticsearchServerIdentity.version(body: Data(#"{"version":{"number":"8.1"}}"#.utf8), headers: [:]) }
    }
    @Test func redisInitialScopeUsesCanonicalLogicalDatabaseIndex() async {
        var profile = Self.profile(); profile.database = "DB 1"
        let model = MobileResourceModel(profile: profile, password: nil, service: ResourceTestService())
        await model.load()?.value; await model.loadCatalog()?.value
        #expect(model.scope == "1"); #expect(model.catalog?.first?.name == "new_scope")
    }
    @Test func resourceFirstEmptyFailureAndRetry() async throws {
        let service = ResourceTestService()
        let model = MobileResourceModel(profile: Self.profile(), password: nil, service: service)
        #expect(model.catalog == nil); #expect(model.details == nil)
        await model.load()?.value; await model.loadCatalog()?.value
        #expect(model.catalog?.count == 1)
        await service.failCatalog(true)
        await model.loadCatalog()?.value
        #expect(model.catalog?.count == 1); #expect(model.catalogError != nil)
        await service.failCatalog(false); await service.setEmpty(true)
        await model.loadCatalog()?.value
        #expect(model.catalog?.isEmpty == true); #expect(model.catalogError == nil)
        #expect(model.catalogCursor == 7)
    }
    @Test func refreshRetainsDetailsAndLateReplyCannotReplaceNewKey() async throws {
        let service = ResourceTestService()
        let model = MobileResourceModel(profile: Self.profile(), password: nil, service: service)
        await model.load()?.value; await model.loadCatalog()?.value
        let first = MobileResource(name: "first", kind: "key"), second = MobileResource(name: "second", kind: "key")
        model.select(first); await model.loadDetails()?.value
        #expect(model.details?.status == "first")
        await service.holdNext()
        let slow = model.loadDetails()
        await service.waitUntilHeld()
        #expect(model.isLoadingDetails); #expect(model.details?.status == "first")
        model.select(second)
        #expect(model.details == nil)
        await model.loadDetails()?.value
        #expect(model.details?.status == "second")
        await service.release(); await slow?.value
        #expect(model.selected == second); #expect(model.details?.status == "second")
        model.setBackgrounded(true)
        #expect(model.loadDetails() == nil); #expect(!model.isLoading)
    }
    @Test func detailFailurePreservesPageAndRetries() async throws {
        let service = ResourceTestService()
        let model = MobileResourceModel(profile: Self.profile(), password: nil, service: service)
        await model.load()?.value; await model.loadCatalog()?.value
        model.select(.init(name: "first", kind: "key")); await model.loadDetails()?.value
        await service.failDetail(true); await model.loadDetails()?.value
        #expect(model.details?.status == "first"); #expect(model.detailError != nil)
        await service.failDetail(false); await model.loadDetails()?.value
        #expect(model.detailError == nil); #expect(model.details?.status == "first")
    }
    @Test func elasticsearchSearchUsesDesktopMatcherAndOrder() async {
        let model = MobileResourceModel(profile: Self.profile(.elasticsearch), password: nil, service: ResourceTestService())
        await model.load()?.value; await model.loadCatalog()?.value
        model.search = "amu"
        #expect(model.visibleResources.map(\.name) == ["admin_user"])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_ELASTICSEARCH_PORT"] != nil)) func elasticsearchLoopbackReadsRealServer() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_ELASTICSEARCH_PORT"].flatMap(Int.init))
        var profile = Self.profile(.elasticsearch); profile.host = MobileFixtureEndpoint.host; profile.port = port; profile.authentication = .none
        let service = MobileResourceService(profile: profile, password: nil)
        try await service.test()
        let catalog = try await service.catalog(scope: "Elasticsearch", cursor: 0, search: "")
        #expect(catalog.resources.contains { $0.name == "querycraft-ios-proof" && $0.kind == "索引" })
        #expect(catalog.resources.contains { $0.name == "querycraft-ios-alias" && $0.kind == "别名" })
        let detail = try await service.details(resource: .init(name: "querycraft-ios-alias", kind: "别名"), scope: "Elasticsearch", offset: 0, cursor: 0)
        #expect(detail.data.rows.count == 1)
        #expect(detail.data.rows.first?[2]?.contains("你好 Elasticsearch") == true)
        #expect(detail.structure.rows.contains { $0.first == "name" && $0[1] == "text" })
        #expect(!detail.hasNext)
        await #expect(throws: ElasticsearchError.self) { try await service.details(resource: .init(name: "querycraft-ios-proof", kind: "索引"), scope: "Elasticsearch", offset: 10_000, cursor: 0) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_DORIS_PORT"] != nil)) func dorisLoopbackReadsRealServerAndDoesNotOfferEdits() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_DORIS_PORT"].flatMap(Int.init))
        let configuration = MobileSQLConfiguration(host: MobileFixtureEndpoint.host, port: port, username: "root", password: nil, database: "querycraft_ios_drivers", tlsMode: .disabled)
        let service = MobileDorisService()
        #expect(try await service.databases(configuration: configuration).contains("querycraft_ios_drivers"))
        let objects = try await service.objects(configuration: configuration, database: "querycraft_ios_drivers", search: "", kind: .table)
        let object = try #require(objects.objects.first { $0.name == "sample" })
        let columns = try await service.columns(configuration: configuration, object: object)
        #expect(columns.first { $0.name == "name" }?.comment == "真实字段注释")
        let page = try await service.page(configuration: configuration, object: object, columns: columns, offset: 0, size: 1, sortColumn: "id", ascending: true, filter: .empty)
        #expect(page.preview.result.rows.first?[1] == "你好 Doris"); #expect(page.hasNextPage); #expect(!page.hasStableOrder)
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "name", columnKind: .text, operation: .equal, value: "你好 Doris")])
        let filtered = try await service.page(configuration: configuration, object: object, columns: columns, offset: 0, size: 100, sortColumn: "id", ascending: true, filter: filter)
        #expect(filtered.preview.result.rows.count == 1)
        let sql = try await MobileDorisExecutor().execute(configuration: configuration, sql: "SELECT id AS alias, name, id + 1 AS expression FROM sample WHERE id < 0")
        #expect(sql.rows.isEmpty); #expect(sql.columns.count == 3)
        await #expect(throws: MobileQueryError.self) { try await MobileDorisExecutor().execute(configuration: configuration, sql: "DELETE FROM sample") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) func redisLoopbackReadsRealProtocol() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"], let port = Int(raw) else { return }
        var profile = Self.profile(); profile.host = MobileFixtureEndpoint.host; profile.port = port; profile.database = "0"
        let service = MobileResourceService(profile: profile, password: nil)
        try await service.test()
        #expect(try await service.scopes().contains("0"))
        let keys = try await service.catalog(scope: "0", cursor: 0, search: "querycraft-proof:*")
        #expect(keys.resources.contains { $0.name == "querycraft-proof:string" })
        for (key, expected) in [("string", "你好 Redis"), ("list", "first"), ("hash", "field"), ("set", "member"), ("zset", "member")] {
            let detail = try await service.details(resource: .init(name: "querycraft-proof:" + key, kind: "key"), scope: "0", offset: 0, cursor: 0)
            #expect(detail.data.rows.flatMap { $0 }.contains(expected))
        }
    }
}

private actor ResourceTestService: MobileResourceServicing {
    var catalogFails = false, detailFails = false, empty = false, hold = false, holdCatalog = false
    var held: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    func failCatalog(_ value: Bool) { catalogFails = value }
    func failDetail(_ value: Bool) { detailFails = value }
    func setEmpty(_ value: Bool) { empty = value }
    func holdNext() { hold = true }
    func holdNextCatalog() { holdCatalog = true }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { held?.resume(); held = nil }
    func scopes() async throws -> [String] { ["0", "1"] }
    func catalog(scope: String, cursor: UInt64, search: String) async throws -> MobileResourceCatalog {
        if holdCatalog {
            holdCatalog = false
            await withCheckedContinuation { continuation in
                held = continuation
                for waiter in waiters { waiter.resume() }; waiters = []
            }
        }
        if catalogFails { throw MobileQueryError.invalidServerMetadata }
        return .init(resources: empty ? [] : [.init(name: scope == "1" ? "new_scope" : "admin_user", kind: "key")], cursor: empty ? 7 : 0)
    }
    func details(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails {
        if detailFails { throw MobileQueryError.invalidServerMetadata }
        if hold {
            hold = false
            await withCheckedContinuation { continuation in
                held = continuation
                for waiter in waiters { waiter.resume() }; waiters = []
            }
        }
        return .init(data: .init(columns: ["value"], rows: [[resource.name]]), structure: .init(columns: [], rows: []), status: resource.name)
    }
}

private actor DorisMetadataTestExecutor: MobileQueryExecuting {
    var configurations: [MobileSQLConfiguration] = []
    func usedOnlyCatalogConnections() -> Bool { !configurations.isEmpty && configurations.allSatisfy { $0.database == nil } }
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        configurations.append(configuration)
        if sql.hasPrefix("SHOW FULL TABLES") { return .init(columns: ["Tables_in_current", "Table_type"], rows: [["sample", "BASE TABLE"]]) }
        if sql.hasPrefix("SHOW FULL COLUMNS") { return .init(columns: ["Field", "Type", "Null", "Key", "Default", "Extra", "Comment"], rows: [["name", "varchar(80)", "YES", "", nil, "", "real comment"]]) }
        throw MobileQueryError.invalidServerMetadata
    }
}
