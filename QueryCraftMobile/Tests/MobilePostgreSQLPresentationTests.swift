import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobilePostgreSQLPresentationTests: XCTestCase {
    func testLivePostgreSQLWorkspaceRendersSchemaAndKeepsGridOnRefresh() async throws {
        guard let port = ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init) else { throw XCTSkip("Requires isolated PostgreSQL fixture") }
        let profile = MobileConnectionProfile(id: UUID(), name: "PostgreSQL 验证", host: MobileFixtureEndpoint.host, port: port, username: "proof_reader", database: "querycraft_ios_pg", tlsMode: .disabled, remembersPassword: false, requiresPassword: true, driver: .postgresql, schemaName: "audit")
        let app = MobileApplicationModel(repository: PostgreSQLPresentationLibrary(profile))
        app.open(profile, suppliedPassword: "querycraft-proof-pg")
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        XCTAssertNil(workspace.browser.catalogError)
        let object = try XCTUnwrap(workspace.browser.visibleObjects.first { $0.name == "admin_user" && $0.schemaName == "audit" })
        await workspace.browser.selectObject(object)?.value
        XCTAssertNil(workspace.browser.tableError)
        app.destination = .table(object)
        let host = UIHostingController(rootView: MobileLibraryView(app: app).environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); app.showLibrary() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(350))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        XCTAssertEqual(coordinator.parent.data.rows.count, 2)
        XCTAssertEqual(coordinator.parent.data.metadata.first?.origin?.schemaName, "audit")
        let frame = grid.frame, widths = coordinator.widths
        await workspace.browser.loadTable(reloadColumns: true)?.value
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(grid.frame, frame); XCTAssertEqual(coordinator.widths, widths)
        XCTAssertEqual(workspace.browser.selectedSchema, "audit")
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: directory.appending(path: "postgresql-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
        }
    }
    func testLivePostgreSQLTableEntryStagesAndRendersNativeEditor() async throws {
        guard let port = ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init) else { throw XCTSkip("Requires isolated PostgreSQL fixture") }
        let profile = MobileConnectionProfile(id: UUID(), name: "PG 编辑", host: MobileFixtureEndpoint.host, port: port, username: "proof_writer", database: "querycraft_ios_pg", tlsMode: .disabled, remembersPassword: false, requiresPassword: true, driver: .postgresql, schemaName: "mobile_other")
        let app = MobileApplicationModel(repository: PostgreSQLPresentationLibrary(profile))
        app.open(profile, suppliedPassword: "querycraft-proof-pg-writer")
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        let object = try XCTUnwrap(workspace.browser.visibleObjects.first { $0.name == "records" })
        await workspace.browser.selectObject(object)?.value
        let changes = try XCTUnwrap(workspace.browser.currentChanges), page = try XCTUnwrap(workspace.browser.snapshot)
        XCTAssertTrue(workspace.browser.supportsSchemaEditing)
        let request = try changes.request(page: page, row: 0, column: 1)
        let host = UIHostingController(rootView: AnyView(MobileCellEditView(request: request, changes: changes, deleteRow: {})))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); changes.discard(); app.showLibrary() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        let inputs = descendants(host.view)
        XCTAssertTrue(inputs.contains { ($0 as? UITextField)?.text == "other schema" || ($0 as? UITextView)?.text == "other schema" })
        try changes.stage(request, text: "staged from PG entry", mode: .value)
        XCTAssertEqual(changes.displayData(page: page, details: nil).cell(row: 0, column: 1), .text("staged from PG entry"))
        XCTAssertTrue(try changes.previewSQL().contains("UPDATE \"mobile_other\".\"records\""))
        XCTAssertTrue(changes.safetyLock.isEnabled); XCTAssertNil(changes.submit())
        host.rootView = AnyView(MobilePendingChangesView(changes: changes))
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(host.view.bounds.height, 0)
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: directory.appending(path: "postgresql-edit-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
        }
    }
    func testPostgreSQLSessionCacheAndCapturedWriteConfirmationRender() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil else { throw XCTSkip("Requires isolated PostgreSQL fixture") }
        let model = try MobilePostgreSQLSessionTests().model()
        model.sql = "SELECT n AS id, 'PG cache' AS name FROM generate_series(1,1001) n"
        await model.execute()?.value
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.cachedRowCount, 1001)
        let host = UIHostingController(rootView: NavigationStack {
            MobileWorkspaceView(model: model, widthKey: "pg-session-native").environment(\.scenePhase, .active)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        let frame = grid.convert(grid.bounds, to: host.view)
        await model.pageCache(1)?.value
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        XCTAssertEqual(model.cacheOffset, 500); XCTAssertEqual(grid.convert(grid.bounds, to: host.view), frame)
        XCTAssertEqual(model.preview?.workspaceColumns[0].type, "integer")
        model.sql = "UPDATE mobile_session.records SET name='需要确认的 PG 修改' WHERE id=42;"
        model.executionInput.selection = .init(location: 0, length: 0)
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        await model.execute()?.value
        XCTAssertEqual(model.sqlConfirmation?.sql, model.sql); XCTAssertTrue(model.safetyLock.isEnabled)
        try await Task.sleep(for: .milliseconds(650)); host.view.layoutIfNeeded()
        XCTAssertNotNil(host.presentedViewController)
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "postgresql-session-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
        }
        model.sqlConfirmation = nil; await model.disconnectSQL()?.value
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
@MainActor private final class PostgreSQLPresentationLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(_ profile: MobileConnectionProfile) { state = .init(profiles: [profile]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
