import SwiftUI
import UIKit
import QueryCraftMobileCore

@main
struct QueryCraftMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MobileApplicationModel
    @State private var ranLaunchProbe = false
    init() {
        _ = WorkspaceMobileQueryCacheDirectory.current
        #if DEBUG
        if let port = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_MYSQL_PORT"].flatMap(Int.init) {
            let editExperience = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_EDIT_EXPERIENCE"] == "1"
            let tableExperience = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TABLE_ACTIONS"] == "1"
            let profile = MobileConnectionProfile(id: UUID(), name: "MySQL 本地验证", host: "127.0.0.1", port: port,
                username: tableExperience ? "proof_table_admin" : (editExperience ? "proof_writer" : "proof_reader"), database: tableExperience ? "querycraft_ios_table_actions" : (editExperience ? "querycraft_ios_edit" : "querycraft_ios_proof"), tlsMode: .required,
                remembersPassword: false, requiresPassword: true)
            let environment = ProcessInfo.processInfo.environment
            let emptyHome = environment["QUERYCRAFT_PROOF_EMPTY_HOME"] == "1"
            let app = MobileApplicationModel(repository: MobileDebugLibrary(profile: emptyHome ? nil : profile), passwords: MobileDebugPasswords())
            if environment["QUERYCRAFT_PROOF_HOME"] != "1", !emptyHome {
                app.open(profile, suppliedPassword: tableExperience ? "querycraft-proof-table-admin" : (editExperience ? "querycraft-proof-writer" : "querycraft-proof-reader"))
            }
            _model = State(initialValue: app)
            return
        }
        #endif
        _model = State(initialValue: MobileApplicationModel())
    }
    var body: some Scene {
        WindowGroup {
            MobileLibraryView(app: model)
                .onChange(of: scenePhase) { _, phase in
                    // Transient inactive events (Control Center, permission
                    // sheets) must not cancel an intentionally running commit.
                    if phase != .inactive { model.setBackgrounded(phase == .background) }
                }
                .task {
                    #if DEBUG
                    if !ranLaunchProbe, ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_AUTORUN"] == "1", let workspace = model.workspace {
                        ranLaunchProbe = true
                        await workspace.browser.loadDatabases().value
                        if let request = workspace.browser.loadObjects() { await request.value }
                        if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_VIEWS"] == "1" {
                            model.selectTab(.views)
                            await workspace.browser.loadObjects()?.value
                            return
                        }
                        if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_CATALOG"] == "1" {
                            workspace.browser.search = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SEARCH"] ?? ""
                            return
                        }
                        let timestampProbe = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TIMESTAMP"] == "1"
                        let preferredObject = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_OBJECT"] ?? (ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TABLE_ACTIONS"] == "1" ? "action_demo" : timestampProbe ? "epoch_values" : (ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_EDIT_EXPERIENCE"] == "1" ? "edit_rows" : "admin_user"))
                        if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TABLE"] == "1", let object = workspace.browser.catalog?.objects.first(where: { $0.name == preferredObject }) ?? workspace.browser.catalog?.objects.first {
                            model.destination = .table(object)
                            if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SCHEMA"] == "1" {
                                let draft = workspace.schema.draft(for: object)
                                if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SCHEMA_LIST"] == "1" { draft.presentation = .list }
                                if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SCHEMA_INDEX"] == "1" { draft.section = .indexes }
                                workspace.browser.tab = .structure; await workspace.browser.loadTable()?.value
                                return
                            }
                            if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SERVER_FILTER"] == "1" {
                                await workspace.browser.loadTable()?.value
                                let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "id", columnKind: .number,
                                    operation: .between, value: "110", secondValue: "115")])
                                try? await workspace.browser.applyFilter(filter, objectID: object.id)?.value
                            }
                            if let raw = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TABLE_ACTION"], let action = WorkspaceTableAction(rawValue: raw) {
                                await workspace.browser.loadTable()?.value
                                workspace.tableActions.prepare(action, object: object)
                                if action == .rename { workspace.tableActions.request?.input = object.name + "_renamed" }
                            }
                            if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_STRUCTURE"] == "1" {
                                workspace.browser.tab = .structure
                                await workspace.browser.loadTable()?.value
                            }
                        } else {
                            let queryEditing = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_QUERY_EDIT"] == "1"
                            workspace.query.database = queryEditing ? "querycraft_ios_edit" : "querycraft_ios_proof"
                            workspace.query.sql = queryEditing
                                ? "SELECT id AS `编号`, name AS `名称`, amount AS `金额`, CONCAT(name, '!') AS `计算值` FROM edit_rows ORDER BY id;"
                                : "SELECT id AS 编号, name AS 名称, nullable_value AS 可空值, payload, amount AS 金额 FROM sample ORDER BY id LIMIT 100;"
                            if timestampProbe {
                                workspace.query.sql = "SELECT created_at AS alias, updated_at, id, created_at + 0 AS expression, created_time FROM epoch_values ORDER BY id;"
                            }
                            if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SQL_TARGET"] == "1" {
                                let target = "SELECT id AS `编号`, name AS `名称`, amount AS `金额` FROM edit_rows ORDER BY id;"
                                workspace.query.sql = "SELECT '另一条查询' AS note;\n\n" + target + "\n\nSELECT COUNT(*) FROM edit_rows;"
                                workspace.query.executionInput.selection = .init(location: (workspace.query.sql as NSString).range(of: "FROM edit_rows").location, length: 0)
                            }
                            model.destination = .query
                            await workspace.query.execute()?.value
                        }
                        if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_LANDSCAPE"] == "1",
                           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                        }
                    }
                    #endif
                }
        }
    }
}

#if DEBUG
@MainActor private final class MobileDebugLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(profile: MobileConnectionProfile?) { state = .init(profiles: profile.map { [$0] } ?? []) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
@MainActor private final class MobileDebugPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws { }
}
#endif
