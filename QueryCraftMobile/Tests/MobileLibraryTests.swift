import QueryCraftMobileCore
import XCTest
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileLibraryTests: XCTestCase {
    func testTypingCatalogSearchIsLocalAndRefreshKeepsSearch() async throws {
        let service = LibraryBrowserService()
        let app = MobileApplicationModel(repository: TestLibrary(), passwords: TestPasswords(), service: service)
        let draft = MobileConnectionDraft(); draft.name = "search"; draft.database = "db"
        app.open(try draft.profile())
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value
        await workspace.browser.loadObjects()?.value
        let before = await service.callCount()
        workspace.browser.search = "smp"
        XCTAssertEqual(workspace.browser.visibleObjects.map(\.name), ["sample"])
        workspace.browser.search = "NO_MATCH"
        XCTAssertTrue(workspace.browser.visibleObjects.isEmpty)
        workspace.browser.search = "SMP"
        let afterTyping = await service.callCount()
        XCTAssertEqual(before, afterTyping)
        await workspace.browser.loadObjects()?.value
        XCTAssertEqual(workspace.browser.search, "SMP")
        XCTAssertEqual(workspace.browser.visibleObjects.map(\.name), ["sample"])
        workspace.browser.selectDatabase("other")
        XCTAssertNil(workspace.browser.catalog)
        XCTAssertTrue(workspace.browser.search.isEmpty)
    }

    func testHomeStaysSeparateUntilPasswordIsProvided() throws {
        let repository = TestLibrary(), service = LibraryBrowserService()
        let draft = MobileConnectionDraft(); draft.name = "saved"; draft.password = "required"
        let profile = try draft.profile()
        repository.state.profiles = [profile]
        let app = MobileApplicationModel(repository: repository, passwords: TestPasswords(), service: service)
        XCTAssertFalse(app.isWorkspacePresented); XCTAssertNil(app.workspace)
        app.open(profile)
        XCTAssertEqual(app.passwordPrompt?.id, profile.id)
        XCTAssertFalse(app.isWorkspacePresented); XCTAssertNil(app.workspace)
        app.open(profile, suppliedPassword: "required")
        XCTAssertTrue(app.isWorkspacePresented); XCTAssertNil(app.passwordPrompt)
        XCTAssertEqual(app.workspace?.profile.id, profile.id)
    }

    func testReturningHomeAndReopeningPreservesWorkspaceAndLoadedCatalog() async throws {
        let service = LibraryBrowserService()
        let app = MobileApplicationModel(repository: TestLibrary(), passwords: TestPasswords(), service: service)
        let draft = MobileConnectionDraft(); draft.name = "saved"; draft.database = "db"
        let profile = try draft.profile()
        app.open(profile)
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value
        await workspace.browser.loadObjects()?.value
        let calls = await service.callCount()
        workspace.query.sql = "SELECT 'keep draft'"
        app.destination = .query
        let previousStatus = workspace.query.status
        app.showLibrary()
        XCTAssertFalse(app.isWorkspacePresented)
        XCTAssertNil(app.destination)
        XCTAssertFalse(app.isLoading)
        XCTAssertEqual(workspace.query.status, previousStatus)
        app.open(profile)
        await Task.yield()
        XCTAssertTrue(app.isWorkspacePresented)
        XCTAssertEqual(app.workspace?.id, workspace.id)
        XCTAssertEqual(app.workspace?.query.sql, "SELECT 'keep draft'")
        XCTAssertEqual(app.workspace?.browser.catalog?.objects.first?.name, "sample")
        let resumedCalls = await service.callCount()
        XCTAssertEqual(resumedCalls, calls)
    }

    func testTabsKeepQueryDraftAndScopeRefreshToCurrentCatalog() async throws {
        let app = MobileApplicationModel(repository: TestLibrary(), passwords: TestPasswords(), service: LibraryBrowserService())
        let draft = MobileConnectionDraft(); draft.name = "tabs"; draft.database = "db"
        app.open(try draft.profile())
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value
        await workspace.browser.loadObjects()?.value
        workspace.query.sql = "SELECT 'draft'"
        app.selectTab(.query)
        XCTAssertEqual(app.destination, .query)
        app.selectTab(.views)
        await workspace.browser.loadObjects()?.value
        XCTAssertEqual(workspace.browser.catalogKind, .view)
        XCTAssertNil(app.destination)
        XCTAssertEqual(workspace.browser.catalog?.objects.first?.kind, .view)
        app.refresh()
        await workspace.browser.loadObjects()?.value
        XCTAssertEqual(workspace.browser.catalog?.objects.first?.kind, .view)
        app.selectTab(.tables)
        await workspace.browser.loadObjects()?.value
        XCTAssertEqual(workspace.browser.catalog?.objects.first?.kind, .table)
        app.selectTab(.query)
        XCTAssertEqual(workspace.query.sql, "SELECT 'draft'")
        XCTAssertEqual(app.workspaceTab, .query)
    }

    func testDeletingCurrentConnectionReturnsToHome() throws {
        let repository = TestLibrary(), draft = MobileConnectionDraft(); draft.name = "saved"
        let profile = try draft.profile(); repository.state.profiles = [profile]
        let app = MobileApplicationModel(repository: repository, passwords: TestPasswords(), service: LibraryBrowserService())
        app.open(profile)
        XCTAssertTrue(app.isWorkspacePresented)
        try app.delete(profile)
        XCTAssertFalse(app.isWorkspacePresented)
        XCTAssertNil(app.workspace); XCTAssertTrue(app.library.profiles.isEmpty)
    }

    func testDeviceKeychainRoundTripsAndRemovesOwnedCredential() throws {
        let store = MobileKeychainStore(), id = UUID()
        defer { try? store.setPassword(nil, for: id) }
        XCTAssertNil(try store.password(for: id))
        try store.setPassword("first-secret", for: id)
        XCTAssertEqual(try store.password(for: id), "first-secret")
        try store.setPassword("changed-secret", for: id)
        XCTAssertEqual(try store.password(for: id), "changed-secret")
        try store.setPassword(nil, for: id)
        XCTAssertNil(try store.password(for: id))
    }
    func testConnectionFileHasNoPasswordAndRoundTripsUnicode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MobileLibraryRepository(file: directory.appendingPathComponent("connections.json"))
        let draft = MobileConnectionDraft(); draft.name = "测试连接"; draft.password = "secret-not-in-json"
        let profile = try draft.profile()
        try repository.write(.init(profiles: [profile]))
        let text = try String(contentsOf: repository.file, encoding: .utf8)
        XCTAssertFalse(text.contains(draft.password))
        XCTAssertEqual(try repository.load().profiles, [profile])
    }
    func testCorruptFileIsNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("bad json".utf8).write(to: file)
        let app = MobileApplicationModel(repository: MobileLibraryRepository(file: file), passwords: TestPasswords())
        XCTAssertFalse(app.libraryLoaded)
        let draft = MobileConnectionDraft(); draft.name = "new"
        XCTAssertThrowsError(try app.save(draft))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bad json")
    }
    func testSaveFailureRestoresExistingCredentialAndProfile() throws {
        let repository = TestLibrary(), passwords = TestPasswords()
        let draft = MobileConnectionDraft(); draft.name = "existing"; draft.password = "new"; draft.remembersPassword = true
        let profile = try draft.profile()
        repository.state.profiles = [profile]
        passwords.values[profile.id] = "old"
        let app = MobileApplicationModel(repository: repository, passwords: passwords)
        repository.failWrites = true
        XCTAssertThrowsError(try app.save(draft))
        XCTAssertEqual(passwords.values[profile.id], "old")
        XCTAssertEqual(app.library.profiles, [profile])
        XCTAssertNil(app.workspace)
        XCTAssertThrowsError(try app.delete(profile))
        XCTAssertEqual(passwords.values[profile.id], "old")
        XCTAssertEqual(app.library.profiles, [profile])
    }
    func testHistoryIsBoundedDeduplicatedAndScopedToConnectionAndDatabase() throws {
        let repository = TestLibrary(), app = MobileApplicationModel(repository: repository, passwords: TestPasswords())
        let profileID = UUID()
        for value in 0..<60 { app.recordQuery(sql: "SELECT \(value)", database: "db", profileID: profileID) }
        XCTAssertEqual(app.library.history.count, 50)
        app.recordQuery(sql: "SELECT 59", database: "db", profileID: profileID)
        XCTAssertEqual(app.library.history.count, 50)
        XCTAssertEqual(app.library.history.filter { $0.sql == "SELECT 59" }.count, 1)
        app.recordQuery(sql: "SELECT 59", database: "other", profileID: profileID)
        XCTAssertEqual(app.library.history.filter { $0.sql == "SELECT 59" }.count, 2)
        app.recordQuery(sql: String(repeating: "x", count: 16_385), database: "db", profileID: profileID)
        XCTAssertEqual(app.library.history.first?.database, "other")
    }
}
@MainActor private final class TestLibrary: MobileLibraryPersisting {
    var state = MobileLibraryState(), failWrites = false
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { if failWrites { throw TestFailure.expected }; self.state = state }
    enum TestFailure: Error { case expected }
}
@MainActor private final class TestPasswords: MobilePasswordStoring {
    var values: [UUID: String] = [:]
    func password(for id: UUID) throws -> String? { values[id] }
    func setPassword(_ password: String?, for id: UUID) throws { values[id] = password }
}

private actor LibraryBrowserService: MobileSQLServicing {
    private var calls = 0
    func callCount() -> Int { calls }
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] { calls += 1; return ["db"] }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        calls += 1
        return .init(objects: [.init(database: database, name: kind == .view ? "sample_view" : "sample", kind: kind ?? .table, comment: "")], hasMore: false)
    }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] { throw UnexpectedRequest.request }
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot { throw UnexpectedRequest.request }
    private enum UnexpectedRequest: Error { case request }
}
