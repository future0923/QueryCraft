import XCTest

/// OS-driven interaction, separate from in-process UIKit presentation tests.
@MainActor final class MobilePhysicalSystemUITests: XCTestCase {
    private var app: XCUIApplication!
    private var owner = UUID()

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PROOF_SERVER_HOST"], let port = environment["PROOF_MYSQL_PORT"] else {
            throw XCTSkip("Requires the owned physical UI MySQL fixture")
        }
        owner = UUID()
        app = XCUIApplication()
        app.launchEnvironment = ["QUERYCRAFT_PROOF_MYSQL_PORT": port, "QUERYCRAFT_PROOF_HOST": host,
                                 "QUERYCRAFT_PROOF_SYSTEM_OWNER": owner.uuidString]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
    }

    override func tearDown() async throws {
        if let app {
            capture("final-state")
            app.terminate()
            app.launchEnvironment["QUERYCRAFT_PROOF_SYSTEM_CLEANUP"] = "1"
            app.launchEnvironment["QUERYCRAFT_PROOF_EMPTY_HOME"] = "1"
            app.launch()
            XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 15))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    private var editor: XCUIElement { app.textViews["sqlEditor"].firstMatch }
    private func hideKeyboard() {
        let button = app.buttons["收起键盘"]
        if button.exists { button.tap() }
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func enterSQL(_ sql: String, atEnd: Bool = false) {
        if atEnd { editor.coordinate(withNormalizedOffset: .init(dx: 0.97, dy: 0.95)).tap() }
        else { editor.tap() }
        // Third-party keyboards can be visible without exposing a Keyboard AX
        // element. The app's focus control is shared by all input methods.
        XCTAssertTrue(app.buttons["收起键盘"].waitForExistence(timeout: 15), "Editor must acknowledge input focus before typing")
        let before = editor.value as? String
        editor.typeText(sql)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", sql), object: editor)
        let delivered = XCTWaiter.wait(for: [updated], timeout: 5)
        if delivered != .completed, editor.value as? String == before {
            // Initial third-party keyboard activation may consume the first
            // event. Retry only when absolutely no text changed, before any SQL
            // execution; partial input must fail rather than replay characters.
            capture("physical-first-input-not-delivered")
            if atEnd { editor.coordinate(withNormalizedOffset: .init(dx: 0.97, dy: 0.95)).tap() }
            else { editor.tap() }
            editor.typeText(sql)
            let retry = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", sql), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [retry], timeout: 5), .completed, "Text after typing retry: \(String(describing: editor.value))")
        } else {
            XCTAssertEqual(delivered, .completed, "Text after typing: \(String(describing: editor.value))")
        }
        XCTAssertEqual((editor.value as? String)?.components(separatedBy: sql).count, 2, "SQL must be inserted exactly once")
        hideKeyboard()
        XCTAssertTrue((editor.value as? String)?.contains(sql) == true, "Text after dismissing keyboard: \(String(describing: editor.value))")
    }
    private func typeAndRun(_ sql: String) {
        enterSQL(sql)
        app.buttons["executeQuery"].tap()
        XCTAssertTrue(app.collectionViews["queryResults"].waitForExistence(timeout: 20), app.debugDescription)
    }

    private func openLibrarySettings() {
        let home = app.buttons["backToConnections"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10)); home.tap()
        let settings = app.buttons["openSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["settings.data"].waitForExistence(timeout: 10))
    }
    private func reopenConnection() {
        let connection = app.buttons["connection." + owner.uuidString]
        XCTAssertTrue(connection.waitForExistence(timeout: 10), app.debugDescription)
        connection.tap()
        // Opening a connection intentionally starts at its table catalog.
        // Follow each platform's existing navigation to the retained SQL draft.
        if app.tabBars.buttons["查询"].exists { app.tabBars.buttons["查询"].tap() }
        else {
            let navigation = app.buttons["MySQL 本地验证 · 表"]
            XCTAssertTrue(navigation.waitForExistence(timeout: 10), app.debugDescription)
            navigation.tap()
            app.buttons["查询"].firstMatch.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["openSettings"].exists, "Only the connection library exposes settings")
    }

    func testKeyboardExecutionBackgroundAndRealProcessRecovery() throws {
        let sql = "SELECT 'recovery-\(owner.uuidString)' AS marker;"
        typeAndRun(sql)
        let draft = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(draft.contains(sql), "Actual draft: \(draft)")
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "marker，recovery-" + owner.uuidString)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        capture("physical-keyboard-query")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        capture("physical-home-screen")
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, draft)
        app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, draft)
        // The empty grid remains mounted to keep the loading layout stable.
        XCTAssertEqual(app.collectionViews["queryResults"].cells.count, 0, "Result rows must not be restored or replayed")
        XCTAssertFalse(result.exists)
        capture("physical-restored-draft-without-results")
        app.buttons["executeQuery"].tap()
        XCTAssertTrue(app.collectionViews["queryResults"].waitForExistence(timeout: 20))
        XCTAssertTrue(result.waitForExistence(timeout: 10))
    }

    func testSystemDataExportPickerAndRotation() throws {
        typeAndRun("SELECT 42 AS answer, 'physical export' AS label;")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["resultOptions"].waitForExistence(timeout: 10))
        capture("physical-landscape-results")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["resultOptions"].tap()
        let export = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "导出")).firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5)); export.tap()
        let prepare = app.buttons["prepareDataExport"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10), app.debugDescription); prepare.tap()
        // UIDocumentPicker runs out of process; observe its actual controls.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        capture("physical-system-files-export")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "system-files-export-accessibility"; tree.lifetime = .keepAlways; add(tree)
        cancel.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews["queryResults"].exists)
    }

    func testRealBackgroundRollsBackTransactionAndCancelsSlowServerRead() throws {
        typeAndRun("SELECT 11 AS original;")
        let controls = app.buttons["sqlSessionControls"]
        controls.tap(); app.buttons["开始事务"].tap()
        let active = NSPredicate(format: "label CONTAINS %@", "事务进行中")
        expectation(for: active, evaluatedWith: controls)
        waitForExpectations(timeout: 15)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "NOT (label CONTAINS %@)", "事务进行中"), evaluatedWith: controls)
        waitForExpectations(timeout: 15)
        enterSQL("\nSELECT SLEEP(8) AS slow;", atEnd: true)
        app.buttons["executeQuery"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        let execute = app.buttons["executeQuery"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: execute)
        waitForExpectations(timeout: 15)
        XCTAssertTrue((editor.value as? String)?.contains("SELECT SLEEP(8)") == true)
        capture("physical-background-cancelled-read")
    }

    func testSystemThemeImportCancelPreservesDraftAndForeground() throws {
        let sql = "SELECT 'theme-\(owner.uuidString)';"
        enterSQL(sql)
        let draft = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(draft.contains(sql))
        openLibrarySettings()
        app.buttons["settings.editor"].tap()
        let importing = app.buttons["导入主题"]
        for _ in 0..<8 where !importing.isHittable { app.swipeUp() }
        XCTAssertTrue(importing.isHittable); importing.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        capture("physical-system-files-import")
        cancel.tap()
        app.navigationBars["编辑器设置"].buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        reopenConnection()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, draft)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, draft)
    }

    func testSettingsApplyToExistingQueryAndPersistAcrossRealRelaunch() throws {
        typeAndRun("SELECT 1700000000 AS created_at, NULL AS nullable;")
        let result = app.collectionViews["queryResults"]
        let draft = try XCTUnwrap(editor.value as? String)
        openLibrarySettings()
        capture("physical-native-settings-home-light")
        let data = app.buttons["settings.data"]
        XCTAssertTrue(data.waitForExistence(timeout: 10), app.debugDescription)
        data.tap()
        let timestamps = app.switches["settings.timestamps"]
        XCTAssertTrue(timestamps.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(timestamps.value as? String, "1")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "settings-controls-before-toggle"; tree.lifetime = .keepAlways; add(tree)
        timestamps.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: timestamps)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        app.switches["settings.columnDetails"].coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.5)).tap()
        capture("physical-settings-data")
        app.navigationBars["表格与记录"].buttons.firstMatch.tap()
        app.buttons["settings.appearanceLink"].tap()
        app.buttons["settings.appearance"].tap()
        app.buttons["深色"].tap()
        capture("physical-native-settings-appearance-dark")
        app.navigationBars["外观"].buttons.firstMatch.tap()
        capture("physical-native-settings-home-dark")
        app.buttons["完成"].tap()
        reopenConnection()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertTrue(result.exists)
        let raw = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "created_at，1700000000")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10), app.debugDescription)
        capture("physical-settings-applied-raw-result")
        app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, draft)
        openLibrarySettings()
        app.buttons["settings.data"].tap()
        XCTAssertTrue(timestamps.waitForExistence(timeout: 10))
        XCTAssertEqual(timestamps.value as? String, "0")
        XCTAssertEqual(app.switches["settings.columnDetails"].value as? String, "0")
        capture("physical-settings-restored-after-relaunch")
        app.navigationBars["表格与记录"].buttons.firstMatch.tap()
        app.buttons["settings.export"].tap()
        XCTAssertTrue(app.buttons["CSV"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["CSV"].tap()
        XCTAssertTrue(app.switches["UTF-8 BOM"].waitForExistence(timeout: 10))
        capture("physical-settings-export-defaults")
    }
}
