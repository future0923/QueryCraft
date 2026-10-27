import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

/// Opt-in acceptance on the connected phone. Credentials stay in its Keychain.
@MainActor final class MobilePhysicalSQLAcceptanceTests: XCTestCase {
    func testPhysicalSQLConnectionPreflight() async throws {
        try authorize()
        let env = ProcessInfo.processInfo.environment
        if env["QUERYCRAFT_PHYSICAL_MYSQL_HOST"] != nil, env["QUERYCRAFT_PHYSICAL_PG_HOST"] != nil {
            for config in [try mysqlConfiguration(), try postgresConfiguration()] {
                let result = try await read(config, "SELECT 1 AS physical_probe")
                XCTAssertEqual(result.rows, [["1"]])
            }
            attach("MySQL and PostgreSQL isolated fixture SELECT 1 passed; no saved profiles accessed", name: "physical-sql-preflight")
            return
        }
        let profiles = try MobileLibraryRepository().load().profiles.filter { $0.driver == .mysql || $0.driver == .postgresql }
        var report: [String] = []
        for driver in [MobileDriver.mysql, .postgresql] {
            let candidates = profiles.filter { $0.driver == driver }
            report.append("\(driver.rawValue): saved profiles=\(candidates.count)")
            for profile in candidates {
                let password = try MobileKeychainStore().password(for: profile.id)
                guard !profile.requiresPassword || password != nil else {
                    report.append("profile=\(profile.id): missing saved credential"); continue
                }
                let config = profile.configuration(password: password)
                do {
                    let result = try await read(config, "SELECT 1 AS physical_probe")
                    XCTAssertEqual(result.rows, [["1"]])
                    report.append("profile=\(profile.id): SELECT 1 passed; database configured=\(!profile.database.isEmpty)")
                } catch {
                    // Never include connection configuration or credentials in attachments.
                    report.append("profile=\(profile.id): connection failed (\(String(describing: type(of: error))))")
                }
            }
        }
        attach(report.joined(separator: "\n"), name: "physical-sql-preflight")
    }

    func testPhysicalMySQLNativeInputFilterAndEditing() async throws {
        try authorize()
        try await acceptance(mysqlConfiguration())
    }

    func testPhysicalMySQLCleanup() async throws {
        try authorize()
        let owner = try XCTUnwrap(ProcessInfo.processInfo.environment["QUERYCRAFT_PHYSICAL_SQL_OWNER"])
        guard UUID(uuidString: owner) != nil else { throw MobileQueryError.invalidConnection }
        let table = "qc_ios_admin_user_" + owner.replacingOccurrences(of: "-", with: "").lowercased()
        try await cleanup(mysqlConfiguration(), table: table, owner: owner)
        attach("Owned MySQL table absent after independent cleanup: " + table, name: "mysql-independent-cleanup")
    }

    private func mysqlConfiguration() throws -> MobileSQLConfiguration {
        let env = ProcessInfo.processInfo.environment
        if let host = env["QUERYCRAFT_PHYSICAL_MYSQL_HOST"] {
            return .init(host: host, port: try XCTUnwrap(env["QUERYCRAFT_PHYSICAL_MYSQL_PORT"].flatMap(Int.init)),
                username: "physical_acceptance", password: try XCTUnwrap(env["QUERYCRAFT_PHYSICAL_MYSQL_PASSWORD"]),
                database: "physical_acceptance", tlsMode: .required)
        }
        let profiles = try MobileLibraryRepository().load().profiles.filter { $0.driver == .mysql }
        let id = ProcessInfo.processInfo.environment["QUERYCRAFT_PHYSICAL_MYSQL_PROFILE"].flatMap(UUID.init(uuidString:))
        let profile = try XCTUnwrap(id.flatMap { id in profiles.first { $0.id == id } } ?? (profiles.count == 1 ? profiles.first : nil))
        let password = try MobileKeychainStore().password(for: profile.id)
        guard !profile.requiresPassword || password != nil else { throw MobileQueryError.invalidConnection }
        return profile.configuration(password: password)
    }

    func testPhysicalPostgreSQLNativeInputFilterAndEditing() async throws {
        try authorize()
        try await acceptance(postgresConfiguration())
    }

    private func postgresConfiguration() throws -> MobileSQLConfiguration {
        let env = ProcessInfo.processInfo.environment
        return MobileSQLConfiguration(host: try XCTUnwrap(env["QUERYCRAFT_PHYSICAL_PG_HOST"]),
            port: try XCTUnwrap(env["QUERYCRAFT_PHYSICAL_PG_PORT"].flatMap(Int.init)), username: "physical_acceptance",
            password: try XCTUnwrap(env["QUERYCRAFT_PHYSICAL_PG_PASSWORD"]), database: "physical_acceptance", tlsMode: .disabled,
            driver: .postgresql, schemaName: "public")
    }

    private func acceptance(_ config: MobileSQLConfiguration) async throws {
        let owner = try XCTUnwrap(ProcessInfo.processInfo.environment["QUERYCRAFT_PHYSICAL_SQL_OWNER"])
        guard UUID(uuidString: owner) != nil else { throw MobileQueryError.invalidConnection }
        let table = "qc_ios_admin_user_" + owner.replacingOccurrences(of: "-", with: "").lowercased()
        let database = try XCTUnwrap(config.database); XCTAssertFalse(database.isEmpty)
        let pg = config.driver == .postgresql
        let quote: (String) -> String = { pg ? PostgreSQLCatalog.identifier($0) : MobileMySQLService.identifier($0) }
        let target = quote(pg ? "public" : database) + "." + quote(table)
        let object = MobileDatabaseObject(database: database, name: table, kind: .table, comment: owner, schemaName: pg ? "public" : nil)
        let service: any MobileSQLServicing = pg ? MobilePostgreSQLService() : MobileMySQLService()
        let mutations: any MobileDataMutating = pg ? MobilePostgreSQLMutationService() : MobileDataMutationService()
        let executor: any MobileQueryExecuting = pg ? MobilePostgreSQLExecutor() : MobileMariaDBExecutor()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        var created = false
        var phase = "create-table"
        do {
            let ddl = "CREATE TABLE " + target + " (id BIGINT PRIMARY KEY, name VARCHAR(128) NOT NULL, note TEXT NULL, amount DECIMAL(12,2))" + (pg ? "" : " ENGINE=InnoDB COMMENT='" + owner + "'")
            _ = try await raw(config, ddl); created = true
            phase = "comment-table"
            if pg { _ = try await raw(config, "COMMENT ON TABLE " + target + " IS '" + owner + "'") }
            phase = "seed-rows"
            _ = try await raw(config, "INSERT INTO " + target + " (id,name,note,amount) VALUES (9007199254740993,'before',NULL,1.25),(9007199254740994,'second','',2.50),(9007199254740995,'third','note',3.75)")

            let browser = MobileBrowserModel(configuration: config, service: service, mutationService: mutations)
            defer { browser.cancelAll() }
            browser.restoreDatabaseContext(database: database, schema: pg ? "public" : nil)
            phase = "load-catalog"
            await browser.loadObjects()?.value
            XCTAssertNil(browser.catalogError)
            phase = "mount-catalog"
            let app = MobileApplicationModel(repository: PhysicalSQLLibrary())
            let catalogHost = UIHostingController(rootView: NavigationStack { MobileCatalogView(app: app, browser: browser, kind: .table) }.mobileAppearance())
            window.rootViewController = catalogHost; window.makeKeyAndVisible(); try await settle(catalogHost)
            let search = try XCTUnwrap(descendants(catalogHost.view).compactMap { $0 as? UISearchBar }.first)
            for term in ["ad", "amu"] {
                search.searchTextField.becomeFirstResponder(); search.searchTextField.selectAll(nil); search.searchTextField.insertText(term)
                search.searchTextField.sendActions(for: .editingChanged)
                search.delegate?.searchBar?(search, textDidChange: term)
                try await settle(catalogHost)
                XCTAssertEqual(browser.search, term)
                XCTAssertTrue(browser.visibleObjects.contains { $0.name == table }, "Desktop fuzzy matching on real catalog")
            }
            capture(window, config.driver.rawValue + "-catalog-search")
            window.endEditing(true); browser.search = ""
            browser.pageSize = 1; await browser.selectObject(object)?.value
            XCTAssertNil(browser.tableError)
            XCTAssertEqual(browser.snapshot?.preview.result.rows.first?.first ?? nil, "9007199254740993")
            XCTAssertTrue(browser.snapshot?.hasNextPage == true)
            await browser.loadTable(offset: 1)?.value
            XCTAssertEqual(browser.snapshot?.preview.result.rows.first?.first ?? nil, "9007199254740994")
            let old = browser.snapshot
            let refresh = browser.loadTable(reloadColumns: true)
            XCTAssertEqual(browser.snapshot?.preview.result.rows, old?.preview.result.rows, "Refresh must retain current content")
            await refresh?.value; XCTAssertNil(browser.tableError)
            browser.pageSize = 100; await browser.loadTable(offset: 0)?.value
            let columns = try XCTUnwrap(browser.columns)

            let condition = WorkspaceDatabaseDataFilterCondition(columnName: "name", columnKind: .text, operation: .equal, value: "")
            let draft = MobileTableFilterDraft(object: object, columns: columns, filter: .init(conditions: [condition]))
            let filterHost = UIHostingController(rootView: MobileTableFilterEditor(draft: draft) { _ in }.mobileAppearance())
            window.rootViewController = filterHost; try await settle(filterHost)
            let input = try XCTUnwrap(descendants(filterHost.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "请输入" })
            try primaryAction(containing: input)
            enter("before", input); try await settle(filterHost)
            XCTAssertEqual(draft.filter.conditions.count, 1); XCTAssertEqual(draft.filter.conditions[0].value, "before")
            draft.addCondition(); try await settle(filterHost)
            let remaining = try XCTUnwrap(draft.filter.conditions.last)
            draft.filter.conditions.removeAll { $0.id == condition.id }
            enter("late", input); try await settle(filterHost)
            XCTAssertEqual(draft.filter.conditions.count, 1); XCTAssertEqual(draft.filter.conditions.first?.id, remaining.id)
            XCTAssertEqual(draft.filter.conditions.first?.value, remaining.value, "Removed focused condition cannot edit another row")
            draft.filter = .init(conditions: [.init(columnName: "name", columnKind: .text, operation: .equal, value: "second")])
            window.endEditing(true); try await settle(filterHost); capture(window, config.driver.rawValue + "-filter")
            await (try browser.applyFilter(draft.filter, objectID: object.id))?.value
            XCTAssertEqual(browser.snapshot?.preview.result.rows.map { $0[1] }, ["second"])
            var empty = draft.filter; empty.conditions[0].value = "never-" + owner
            await (try browser.applyFilter(empty, objectID: object.id))?.value
            XCTAssertTrue(browser.snapshot?.preview.result.rows.isEmpty == true)
            XCTAssertEqual(browser.snapshot?.preview.result.columns.count, 4)
            await (try browser.applyFilter(.empty, objectID: object.id))?.value
            XCTAssertEqual(browser.snapshot?.preview.result.rows.count, 3)

            let model = MobileQueryModel(executor: executor, metadataService: service, mutationService: mutations)
            model.driver = config.driver; model.host = config.host; model.port = String(config.port); model.username = config.username
            model.password = config.password ?? ""; model.database = database; model.schemaName = config.schemaName; model.tlsMode = config.tlsMode
            model.sql = ""
            let sqlHost = UIHostingController(rootView: MobileWorkspaceView(model: model, widthKey: UUID().uuidString).mobileAppearance())
            window.rootViewController = sqlHost; try await settle(sqlHost)
            let sqlInput = try XCTUnwrap(descendants(sqlHost.view).compactMap { $0 as? MobileSQLTextView }.first)
            let sql = "SELECT id AS row_key,name AS display_name,note,amount FROM " + target + " ORDER BY id"
            enter(sql, sqlInput); try await settle(sqlHost)
            XCTAssertEqual(model.sql, sql); window.endEditing(true)
            sqlInput.selectedRange = .init(location: 0, length: 0)
            await model.execute()?.value
            XCTAssertNil(model.errorMessage); XCTAssertEqual(model.result?.rows.count, 3)
            XCTAssertEqual(model.result?.rows[0][0], "9007199254740993"); XCTAssertNil(model.result?.rows[0][2]); XCTAssertEqual(model.result?.rows[1][2], "")
            try await settle(sqlHost); capture(window, config.driver.rawValue + "-query-result")
            let changes = try XCTUnwrap(model.editing, model.editingMessage ?? "No query editing")
            let page = try XCTUnwrap(model.editingPage)
            let request = try changes.request(page: page, row: 0, column: 1)
            XCTAssertEqual(request.column.name, "name"); XCTAssertEqual(request.primaryKey.first?.value, .text("9007199254740993"))
            try await editOnPhone(window, request: request, changes: changes, value: "真机查询修改 雪'\\text", driver: config.driver.rawValue)
            await model.waitForCachePatch()
            let queryReadback = try await read(config, "SELECT name FROM " + target + " WHERE id=9007199254740993")
            XCTAssertEqual(queryReadback.rows, [["真机查询修改 雪'\\text"]])
            XCTAssertEqual(model.sql, sql)
            await model.disconnectSQL()?.value

            await browser.loadTable(reloadColumns: true)?.value
            let tablePage = try XCTUnwrap(browser.snapshot), tableChanges = try XCTUnwrap(browser.currentChanges)
            let tableRequest = try tableChanges.request(page: tablePage, row: 1, column: 1)
            try await editOnPhone(window, request: tableRequest, changes: tableChanges, value: "真机表修改", driver: config.driver.rawValue)
            let tableReadback = try await read(config, "SELECT name FROM " + target + " WHERE id=9007199254740994")
            XCTAssertEqual(tableReadback.rows, [["真机表修改"]])
            let retry = MobileQueryModel(executor: executor, metadataService: service, mutationService: mutations)
            retry.driver = config.driver; retry.host = config.host; retry.port = String(config.port); retry.username = config.username
            retry.password = config.password ?? ""; retry.database = database; retry.schemaName = config.schemaName; retry.tlsMode = config.tlsMode
            retry.sql = "SELECT missing_acceptance_column FROM " + target; await retry.execute()?.value
            XCTAssertNotNil(retry.errorMessage)
            retry.sql = "SELECT count(*) FROM " + target; await retry.execute()?.value
            XCTAssertNil(retry.errorMessage); XCTAssertEqual(retry.result?.rows, [["3"]]); await retry.disconnectSQL()?.value
            try await cleanup(config, table: table, owner: owner)
            created = false
            attach(config.driver.rawValue + ": native catalog search ad/amu, SQL input/execution, paging/refresh, filter input/removal/empty/clear, query and table cell write/readback, failure/retry passed. Owned table removed and metadata existence=0: " + table, name: config.driver.rawValue + "-physical-cleanup")
        } catch {
            attach("driver=" + config.driver.rawValue + "; phase=" + phase + "; errorType=" + String(describing: type(of: error)), name: "physical-sql-failure-phase")
            if created {
                do { try await cleanup(config, table: table, owner: owner) }
                catch { XCTFail("Owned SQL test cleanup failed; rerun explicit cleanup using recorded UUID") }
            }
            throw error
        }
    }

    private func editOnPhone(_ window: UIWindow, request: WorkspaceDatabaseDataCellEditRequest, changes: MobileTableChanges, value: String, driver: String) async throws {
        let host = UIHostingController(rootView: MobileCellEditView(request: request, changes: changes, deleteRow: {}).mobileAppearance())
        window.endEditing(true); window.rootViewController = host; try await settle(host)
        let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.text == request.initialText })
        enter(value, input); try await settle(host)
        XCTAssertEqual(input.text, value); XCTAssertFalse(changes.hasChanges)
        window.endEditing(true); capture(window, driver + (changes.isQueryResult ? "-query-cell-edit" : "-table-cell-edit"))
        try changes.stage(request, text: input.text, mode: .value)
        XCTAssertTrue(changes.hasChanges)
        changes.safetyLock.enable(); XCTAssertNil(changes.submit()); XCTAssertTrue(changes.hasChanges)
        changes.safetyLock.disable(); await changes.submit()?.value
        XCTAssertNil(changes.message); XCTAssertFalse(changes.needsVerification); XCTAssertFalse(changes.hasChanges)
    }
    private func raw(_ config: MobileSQLConfiguration, _ sql: String) async throws -> CDatabaseQueryResult {
        if config.driver == .postgresql {
            let client = LibPQClient(configuration: config.postgreSQL)
            do {
                try await client.connect(); let result = try await client.query(sql); await client.close()
                return .init(columns: result.columns, columnTypes: result.columnTypes, rows: result.rows, affectedRows: UInt64(max(0, result.affectedRows)))
            }
            catch { await client.close(); throw error }
        }
        let client = MariaDBClient(configuration: config)
        do { try await client.connect(); let result = try await client.query(sql); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    private func cleanup(_ config: MobileSQLConfiguration, table: String, owner: String) async throws {
        let pg = config.driver == .postgresql, database = try XCTUnwrap(config.database)
        let literal: (String) -> String = { pg ? PostgreSQLCatalog.literal($0) : MobileMySQLService.literal($0) }
        let infoSQL = pg
            ? "SELECT obj_description(c.oid,'pg_class') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname=" + literal(table)
            : "SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA=" + literal(database) + " AND TABLE_NAME=" + literal(table)
        let info = try await read(config, infoSQL)
        if !info.rows.isEmpty {
            guard info.rows == [[owner]] else { throw MobileQueryError.invalidServerMetadata }
            let quote: (String) -> String = { pg ? PostgreSQLCatalog.identifier($0) : MobileMySQLService.identifier($0) }
            _ = try await raw(config, "DROP TABLE " + quote(pg ? "public" : database) + "." + quote(table))
        }
        let remaining = try await read(config, infoSQL); XCTAssertTrue(remaining.rows.isEmpty)
    }
    private func primaryAction(containing input: UIView) throws {
        var node: UIView? = input
        while node != nil, !(node is UICollectionViewCell) { node = node?.superview }
        let cell = try XCTUnwrap(node as? UICollectionViewCell)
        while node != nil, !(node is UICollectionView) { node = node?.superview }
        let list = try XCTUnwrap(node as? UICollectionView), path = try XCTUnwrap(list.indexPath(for: cell))
        list.delegate?.collectionView?(list, performPrimaryActionForItemAt: path)
    }
    private func enter(_ text: String, _ view: UIView) {
        if let field = view as? UITextField { field.becomeFirstResponder(); field.selectAll(nil); field.insertText(text); field.sendActions(for: .editingChanged) }
        else if let field = view as? UITextView { field.becomeFirstResponder(); field.selectAll(nil); field.insertText(text); field.delegate?.textViewDidChange?(field) }
    }
    private func settle(_ host: UIViewController) async throws { try await Task.sleep(for: .milliseconds(220)); host.view.layoutIfNeeded() }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let a = XCTAttachment(image: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func authorize() throws {
        guard ProcessInfo.processInfo.environment["QUERYCRAFT_PHYSICAL_SQL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Physical SQL acceptance requires explicit user authorization")
        }
    }
    private func read(_ config: MobileSQLConfiguration, _ sql: String) async throws -> CDatabaseQueryResult {
        if config.driver == .postgresql { return try await MobilePostgreSQLExecutor().execute(configuration: config, sql: sql) }
        return try await MobileMariaDBExecutor().execute(configuration: config, sql: sql)
    }
    private func attach(_ text: String, name: String) {
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

@MainActor private struct PhysicalSQLLibrary: MobileLibraryPersisting {
    func load() throws -> MobileLibraryState { .init() }
    func write(_ state: MobileLibraryState) throws {}
}
