import AppKit
import Foundation
import SwiftUI
import ScreenCaptureKit
@testable import QueryCraftFeature

private struct RegressionFailure: Error, CustomStringConvertible { let description: String }
private actor Rows {
    var values: [WorkspaceDatabaseDataRow] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) { values += batch.rows }
}
private actor ProgressSignal {
    var count = 0
    func increment() { count += 1 }
}

/// Runs only against disposable localhost fixtures. No desktop input events are sent.
@MainActor private final class RegressionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct NativeFlowSnapshotLoader: SchemaComparisonSnapshotLoading {
    func load(configuration: DatabaseConnectionConfiguration, progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        try await Task.sleep(for: .milliseconds(1200))
        return try await MySQLSchemaSnapshotLoader(sessionFactory: DefaultWorkspaceSessionFactory())
            .load(configuration: configuration, progress: progress)
    }
}

private struct NativeFailureSnapshotLoader: SchemaComparisonSnapshotLoading {
    func load(configuration: DatabaseConnectionConfiguration, progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        try await Task.sleep(for: .milliseconds(200))
        throw SchemaComparisonError.invalidDatabase
    }
}

private struct NativeCountedSnapshotLoader: SchemaComparisonSnapshotLoading {
    func load(configuration: DatabaseConnectionConfiguration, progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        try await MySQLSchemaSnapshotLoader(sessionFactory: DefaultWorkspaceSessionFactory()).load(configuration: configuration) { event in
            await progress(event)
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

@main
struct SchemaComparisonRegression {
    static let env = ProcessInfo.processInfo.environment
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = RegressionAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(["native", "connections", "performance", "migration", "failure", "reference"].contains(env["QC_REGRESSION_MODE"] ?? "") ? .accessory : .prohibited)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RegressionFailure(description: message) }
    }
    @MainActor static func activate(_ name: String) async throws {
        let path = env["QC_REGRESSION_DRIVERS"]! + "/\(name)-\(env["QC_REGRESSION_ARCH"]!).querycraftdriver"
        guard let bundle = Bundle(path: path) else { throw RegressionFailure(description: "Missing \(name) bundle") }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
            throw RegressionFailure(description: "Invalid \(name) plugin entry")
        }
        try await entry.init().activate()
    }
    static func configuration(_ port: Int, database: String, user: String = "root", password: String? = nil,
                              type: DatabaseType = .mysql) -> DatabaseConnectionConfiguration {
        .init(databaseType: type, host: "127.0.0.1", port: port,
              authentication: type == .kafka ? .none : .usernamePassword(username: user, password: password),
              database: database, tlsMode: .disabled)
    }
    static func snapshot(_ port: Int, _ database: String, user: String = "root", password: String? = nil) async throws -> SchemaComparisonSnapshot {
        try await MySQLSchemaSnapshotLoader(sessionFactory: DefaultWorkspaceSessionFactory())
            .load(configuration: configuration(port, database: database, user: user, password: password), progress: { _ in })
    }
    @MainActor static func model(_ port: Int, source: String = "qc_schema_source", target: String = "qc_schema_target",
                                 targetPort: Int? = nil) async -> WorkspaceSchemaComparisonModel {
        let profiles = [("01 source", source, port), ("02 target", target, targetPort ?? port)].map { name, db, p in
            ConnectionProfile(id: UUID(), name: name, groupID: nil, host: "127.0.0.1", port: p,
                username: "root", defaultDatabase: db, tlsMode: .disabled, storesCredential: false, createdAt: .now)
        }
        let result = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: profiles),
                                                    credentials: InMemoryCredentialStore())
        await result.loadProfiles()
        return result
    }
    @MainActor static func run() async throws {
        let mode = env["QC_REGRESSION_MODE"] ?? "mysql"
        if mode == "drivers" { try await drivers(); return }
        try await activate("MySQL")
        let port = Int(env["QC_SCHEMA_TEST_PORT"]!)!
        if mode == "reference" { try await reference(port); return }
        if mode == "verify-synchronized" {
            let s = try await snapshot(port, "qc_schema_source")
            let t = try await snapshot(Int(env["QC_SCHEMA_TARGET_PORT"]!)!, "qc_schema_target")
            let result = try SchemaComparisonEngine.compare(source: s, target: t)
            try check(result.allSatisfy { $0.status == .equal }, "applied SQL did not converge: " + result.filter { $0.status != .equal }.map { $0.table + "." + $0.object + ":" + $0.changeSummary }.joined(separator: ";"))
            print("PASS actual target re-read after applying complete reviewed SQL: no remaining schema differences")
            return
        }
        if mode == "migration" { try await migration(port); return }
        if mode == "failure" { try await failurePage(port); return }
        if mode == "render" { try await previews(port); return }
        if mode == "faults" { try await faults(port); return }
        if mode == "performance" { try await performance(port); return }
        if mode == "native" { try await native(port); return }
        if mode == "connections" { try await connections(port); return }
        let m = await model(port)
        m.compare(); await m.waitForComparison()
        try check(m.phase == .ready, m.errorMessage ?? "comparison failed")
        try check(m.selectedIDs.isEmpty, "default selection must be empty")
        m.selectAdditions()
        try check(m.selectedDifferences.count == 2, "expected exactly two safe additions")
        let original = m.differences
        try m.script.write(toFile: env["QC_REGRESSION_OUTPUT"]! + "/schema-\(port).sql", atomically: true, encoding: .utf8)
        m.compare(); await m.waitForComparison()
        try check(m.differences == original && m.selectedDifferences.count == 2, "refresh must retain selections")
        m.search = "note"
        try check(m.visibleDifferences.count == 1, "search note")
        m.search = "definitely absent"
        try check(m.visibleDifferences.isEmpty, "empty search")
        m.search = ""
        m.target.database = "qc_schema_source"
        m.compare(); await m.waitForComparison()
        try check(m.phase == .failed && m.script.isEmpty, "same database alias must be rejected")
        m.target.database = "qc_schema_target"
        m.target.password = "incorrect-fixture-password"
        m.compare(); await m.waitForComparison()
        try check(m.phase == .failed && m.differences.isEmpty && !m.canExport, "bad password must not become empty success")
        m.target.password = ""
        m.compare(); await m.waitForComparison()
        try check(m.phase == .ready, "password retry must recover")
        do {
            _ = try await snapshot(port, "qc_schema_target", user: "limited", password: "fixture-only-password")
            throw RegressionFailure(description: "restricted account unexpectedly read target")
        } catch is RegressionFailure { throw RegressionFailure(description: "restricted account unexpectedly read target") }
        catch { }
        let reader = try await snapshot(port, "qc_schema_source", user: "reader", password: "fixture-only-password")
        try check(reader.objects.count == 2 && reader.allowsExport, "read-only account comparison")
        let emptyS = try await snapshot(port, "qc_schema_empty_source")
        let emptyT = try await snapshot(port, "qc_schema_empty_target")
        try check(try SchemaComparisonEngine.compare(source: emptyS, target: emptyT).isEmpty, "empty schemas")
        let complexS = try await snapshot(port, "qc_schema_complex_source")
        let complexT = try await snapshot(port, "qc_schema_complex_target")
        let complex = try SchemaComparisonEngine.compare(source: complexS, target: complexT)
        try check(complex.contains { $0.status == .unavailable }, "partition/invisible definition must be marked incomplete")
        try check(complex.allSatisfy { $0.sql == nil }, "incomplete metadata must block every export")
        try check(complex.contains { $0.sourceDDL.contains("GENERATED ALWAYS") }, "generated expression lost")
        try check(complex.contains { $0.sourceDDL.contains("FOREIGN KEY") }, "foreign key lost")
        let escapedS = try await snapshot(port, "qc_schema_escaped_source")
        let escapedT = try await snapshot(port, "qc_schema_escaped_target")
        let escaped = try SchemaComparisonEngine.compare(source: escapedS, target: escapedT)
        let sql = escaped.compactMap(\.sql).joined(separator: "\n")
        try check(sql.contains("`odd``表`") && sql.contains("`n``ote`") && sql.contains("买家"), "quoted identifier/comment lost")
        try sql.write(toFile: env["QC_REGRESSION_OUTPUT"]! + "/escaped-\(port).sql", atomically: true, encoding: .utf8)
        if let other = env["QC_REGRESSION_OTHER_PORT"].flatMap(Int.init) {
            let cross = await model(port, targetPort: other)
            cross.compare(); await cross.waitForComparison()
            try check(cross.phase == .ready && cross.differences.contains { $0.status == .added }, "cross-version comparison")
            if !MySQLSchemaCompatibility.canExportAdditions(from: cross.sourceVersion, to: cross.targetVersion) {
                try check(cross.differences.allSatisfy { $0.sql == nil }, "unverified downgrade must remain compare-only")
            }
        }
        print("PASS MySQL \(reader.version): live read-only permissions, invalid credentials + retry, same database, empty schemas, refresh selection, complex/escaped DDL and cross-version policy")
    }

    @MainActor static func reference(_ sourcePort: Int) async throws {
        let targetPort = Int(env["QC_SCHEMA_TARGET_PORT"]!)!
        let loaded = await model(sourcePort, targetPort: targetPort)
        let m = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: loaded.profiles),
            credentials: InMemoryCredentialStore(), snapshotLoader: NativeCountedSnapshotLoader())
        await m.loadProfiles()
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "reference window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([window])
        defer { window.orderOut(nil); window.close() }
        try await settle(view)
        let originalFrame = window.frame
        try await press("schemaComparisonConnectionsCompare", in: window)
        var indicator: NSProgressIndicator?
        var indicatorFrame: NSRect?
        var previousFraction = 0.0
        var previousIndicatorValue = 0.0
        var samples = 0
        var capturedProgress = false
        while m.phase == .loading {
            view.layoutSubtreeIfNeeded()
            if let current = descendants(view).compactMap({ $0 as? NSProgressIndicator }).first(where: { $0.accessibilityIdentifier() == "schemaComparisonReadingProgress" }) {
                let frame = current.convert(current.bounds, to: view)
                if let indicator, let indicatorFrame {
                    try check(indicator === current && frame == indicatorFrame && window.frame == originalFrame, "native progress indicator was recreated or moved")
                } else { indicator = current; indicatorFrame = frame }
                if let fraction = m.readingProgress.fraction {
                    try check(!current.isIndeterminate && current.maxValue == 100, "reading indicator must remain determinate")
                    try check(fraction >= previousFraction && current.doubleValue >= previousIndicatorValue, "combined progress moved backwards")
                    previousFraction = fraction; samples += 1
                    previousIndicatorValue = current.doubleValue
                    if !capturedProgress && fraction > 0 && fraction < 1 {
                        try await captureWindow(window, filename: "reference-progress.png")
                        capturedProgress = true
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        await m.waitForComparison(); try await settle(view)
        try check(m.phase == .ready && samples > 3 && capturedProgress, m.errorMessage ?? "real progress samples missing")
        let email = try require(m.differences.first { $0.table == "users" && $0.object == "column:email" }, "email difference")
        try check(email.attributes.map(\.key) == ["type"], "email must explain the actual type change")
        m.focusedID = email.id; try await settle(view)
        _ = try element("schemaComparisonAttributes", in: window)
        try await captureWindow(window, filename: "reference-attributes.png")
        guard let outline = descendants(view).compactMap({ $0 as? NSOutlineView }).first else { throw RegressionFailure(description: "reference outline") }
        try check(outline.numberOfRows > 0 && window.frame == originalFrame, "reference result frame")
        m.selectPlannedChanges(); try await settle(view)
        try check(m.canExport && m.selectedDifferences.contains { $0.sqlForReview?.hasPrefix("CREATE TABLE") == true }
                  && m.selectedDifferences.contains { $0.sqlForReview?.hasPrefix("DROP TABLE") == true }
                  && m.selectedDifferences.contains { $0.sqlForReview?.contains("MODIFY COLUMN") == true }, "complete target-side plan missing")
        try m.script.write(toFile: env["QC_REGRESSION_OUTPUT"]! + "/reference-\(targetPort).sql", atomically: true, encoding: .utf8)
        try await press("schemaComparisonPreview", in: window); try await settle(view)
        try check(window.attachedSheet == nil && window.frame == originalFrame, "review must be a separate stable page")
        try check(!enabled(try element("schemaComparisonPreviewExport", in: window)), "destructive plan bypassed review")
        try await press("schemaComparisonReviewAcknowledgment", in: window); try await settle(view)
        try check(enabled(try element("schemaComparisonPreviewExport", in: window)), "review did not enable export")
        try await captureWindow(window, filename: "reference-review.png")
        let scoped = await model(sourcePort, targetPort: targetPort)
        scoped.options.selectedTables = ["orders"]
        scoped.compare(); await scoped.waitForComparison()
        try check(scoped.phase == .ready && scoped.readingProgress.total == 2 && scoped.readingProgress.completed == 2,
                  scoped.errorMessage ?? "table scope must be applied before metadata collection and counting")
        try check(scoped.differences.allSatisfy { $0.table == "orders" }, "scoped metadata escaped the selection")
        print("PASS reference behavior MySQL \(m.sourceVersion) -> \(m.targetVersion): \(samples) real monotonic progress samples, stable native indicator identity/frame, semantic type differences, target CREATE/MODIFY/DROP plan, index dependencies, native review acknowledgment; \(m.selectedDifferences.count) statements")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RegressionFailure(description: message) }
        return value
    }

    @MainActor static func migration(_ sourcePort: Int) async throws {
        let source = try await snapshot(sourcePort, "qc_schema_source")
        try check(source.version.hasPrefix("5.7."), "migration source must actually be MySQL 5.7")
        let targetPorts = [Int(env["QC_SCHEMA_TARGET_PORT"]!)!, Int(env["QC_SCHEMA_TARGET84_PORT"]!)!]
        for port in targetPorts {
            let target = try await snapshot(port, "qc_schema_target")
            let result = try SchemaComparisonEngine.compare(source: source, target: target)
            try check(result.contains { $0.table == "users" && $0.status == .modified }, "changed column absent")
            try check(result.contains { $0.table == "new_orders" && $0.status == .added }, "source-only table absent")
            try check(result.contains { $0.table == "legacy_events" && $0.status == .targetOnly }, "target-only table absent")
            try check(result.allSatisfy { $0.status != .unavailable }, "5.7 definitions marked incomplete")
            try check(result.filter { $0.object == "column:id" }.allSatisfy { $0.status == .equal }, "integer display width caused false changes")
            try check(result.compactMap(\.sql).count == 2, "compatible forward migration must offer exactly two additions")
            let m = await model(sourcePort, targetPort: port)
            m.compare(); await m.waitForComparison(); m.selectAdditions()
            try check(m.phase == .ready && m.selectedDifferences.count == 2 && m.canExport, m.errorMessage ?? "cross-version model export unavailable")
            try m.script.write(toFile: env["QC_REGRESSION_OUTPUT"]! + "/migration-" + target.version + ".sql", atomically: true, encoding: .utf8)
            print("PASS actual MySQL \(source.version) → \(target.version): \(result.filter { $0.status != .equal }.count) genuine differences, 2 compatible additions, original DDL retained")
        }
        let source80 = try await snapshot(targetPorts[0], "qc_schema_source")
        let target84 = try await snapshot(targetPorts[1], "qc_schema_target")
        let forward80 = try SchemaComparisonEngine.compare(source: source80, target: target84)
        try check(forward80.contains { $0.object == "index:idx_created_at" && $0.sql != nil }, "actual 8.0 → 8.4 compatible index unavailable")
        try check(forward80.contains { $0.object == "column:note" && $0.status == .added }, "actual 8.0 → 8.4 column comparison unavailable")
        let reverse = try SchemaComparisonEngine.compare(source: source80, target: try await snapshot(sourcePort, "qc_schema_target"))
        try check(reverse.compactMap(\.sql).isEmpty && reverse.contains { $0.status == .modified }, "downgrade must compare without planning unverified SQL")
        let m = await model(sourcePort, targetPort: targetPorts[0])
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "migration native window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([window])
        defer { window.orderOut(nil); window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(view)
        try await captureWindow(window, filename: "migration-setup.png")
        try await press("schemaComparisonConnectionsCompare", in: window)
        await m.waitForComparison(); try await settle(view)
        try check(m.phase == .ready && m.sourceVersion.hasPrefix("5.7.") && m.targetVersion.hasPrefix("8.0."), m.errorMessage ?? "native migration did not finish")
        try check(window.attachedSheet == nil && window.title.contains(AppCopy.current.text("选择差异", "Select Changes")), "native title or page transition failed")
        m.selectAdditions(); try await settle(view)
        try await captureWindow(window, filename: "migration-differences.png")
        try await press("schemaComparisonPreview", in: window); try await settle(view)
        try check(window.attachedSheet == nil, "migration review must be a separate page")
        try await captureWindow(window, filename: "migration-review.png")
        try await press("schemaComparisonPreviewDone", in: window); try await settle(view)
        try check(m.selectedDifferences.count == 2, "migration Back lost selected changes")
        print("PASS actual 8.0 → 8.4; blocked downgrade SQL; native 5.7 → 8.0 setup, comparison, selection, review, Back and full window title")
    }

    @MainActor static func failurePage(_ port: Int) async throws {
        let loaded = await model(port)
        let m = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: loaded.profiles),
            credentials: InMemoryCredentialStore(), snapshotLoader: NativeFailureSnapshotLoader())
        await m.loadProfiles()
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "failure window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([window])
        defer { window.orderOut(nil); window.close() }
        try await settle(view)
        try await press("schemaComparisonConnectionsCompare", in: window)
        await m.waitForComparison(); try await settle(view)
        try check(m.phase == .failed && m.differences.isEmpty, "fixture must fail its initial comparison")
        _ = try popup("schemaComparisonSource", in: view)
        try check(descendants(view).compactMap { $0 as? NSOutlineView }.isEmpty, "failed comparison entered an empty results page")
        try await press("label:" + AppCopy.current.text("修改连接", "Edit Connections"), in: window)
        try await settle(view)
        _ = try popup("schemaComparisonTarget", in: view)
        print("PASS initial failure stays on connection page, presents one native error, and Edit Connections restores usable setup")
    }

    @MainActor static func faults(_ port: Int) async throws {
        let control = env["QC_REGRESSION_PROXY_CONTROL"]!
        let active = env["QC_REGRESSION_PROXY_ACTIVE"]!
        func set(_ state: String) throws { try state.write(toFile: control, atomically: true, encoding: .utf8) }
        func noConnections(_ stage: String) async throws {
            for _ in 0..<200 {
                if (try? String(contentsOfFile: active, encoding: .utf8)) == "0" { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw RegressionFailure(description: stage + " leaked a proxy connection: " + ((try? String(contentsOfFile: active, encoding: .utf8)) ?? "missing"))
        }
        let m = await model(port)
        try set("pause")
        m.compare()
        try await Task.sleep(for: .milliseconds(250))
        try check(m.phase == .loading && m.differences.isEmpty && !m.canExport, "slow first load state")
        m.cancel()
        try check(m.isCancelling && !m.canCompare, "cancel must wait for in-flight connect cleanup")
        try set("pass")
        await m.waitForComparison()
        try check(m.phase == .failed && !m.isCancelling && !m.canExport, "canceled request published a result")
        try await noConnections("initial cancellation")
        m.compare(); await m.waitForComparison()
        try check(m.phase == .ready, m.errorMessage ?? "retry")
        m.selectAdditions()
        let previous = m.differences
        try set("pause")
        m.compare(); m.compare()
        try await Task.sleep(for: .milliseconds(250))
        try check(m.differences == previous && !m.canExport, "refresh content/export freshness")
        try set("drop")
        await m.waitForComparison()
        try check(m.phase == .failed && m.differences == previous && m.script.isEmpty, "disconnect did not preserve stale results safely")
        try await noConnections("network failure")
        try set("pass")
        m.compare(); await m.waitForComparison()
        try check(m.phase == .ready && m.canExport, "network retry must restore unchanged selection")
        try set("pause")
        m.compare()
        try await Task.sleep(for: .milliseconds(200))
        m.close()
        try check(m.phase == .idle && m.differences.isEmpty && !m.canExport, "close must invalidate results immediately")
        try set("pass")
        await m.waitForComparison()
        try check(m.phase == .idle && m.differences.isEmpty, "late response after close")
        try await noConnections("close during load")
        print("PASS network faults: delayed first load, cancel + cleanup, repeated refresh, TCP disconnect, stale export blocked, retry, close during load, zero remaining connections")
    }

    @MainActor static func performance(_ port: Int) async throws {
        let m = await model(port, source: "qc_schema_large_source", target: "qc_schema_large_target")
        var ticks = 0
        var maximumPause = 0.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                maximumPause = max(maximumPause, Date().timeIntervalSince(last))
                last = Date(); ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        let start = Date()
        m.compare(); await m.waitForComparison()
        let elapsed = Date().timeIntervalSince(start)
        try check(m.phase == .ready, m.errorMessage ?? "large schema failed")
        try check(Set(m.differences.map(\.table)).count == 1001, "thousand-table inventory lost objects")
        try check(m.differences.filter { $0.status == .added }.count == 1001, "thousand-table additions mismatch")
        m.selectAdditions()
        try check(m.selectedDifferences.count == 1001, "large selection mismatch")
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "large-list window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([window])
        try await settle(view)
        try await press("schemaComparisonConnectionsCompare", in: window)
        try await settle(view)
        guard let list = descendants(view).compactMap({ $0 as? NSOutlineView }).first else { throw RegressionFailure(description: "large-list native outline") }
        // Large catalogs show table nodes, plus the current object's expanded row.
        try check((1002...1004).contains(list.numberOfRows), "large-list grouped row count: \(list.numberOfRows)")
        let scrollStart = Date()
        list.scrollRowToVisible(list.numberOfRows - 1)
        try await settle(view)
        let scrollTime = Date().timeIntervalSince(scrollStart)
        try check(list.rows(in: list.visibleRect).contains(list.numberOfRows - 1), "large-list scroll destination")
        let selectionStart = Date()
        m.compare(); await m.waitForComparison()
        try check(m.selectedDifferences.count == 1001, "large refresh selection mismatch")
        let refreshed = Date().timeIntervalSince(selectionStart)
        m.search = "wide_table"
        try check(m.visibleDifferences.count == 1 && m.visibleDifferences[0].sourceDDL.count > 4000, "wide table DDL/filter")
        m.search = ""
        m.compare()
        // Wait for a real metadata request, then cancel; this does not inject desktop input.
        for _ in 0..<200 {
            if m.progress.contains("/") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let canceledAt = Date(); m.cancel(); await m.waitForComparison()
        let cancelTime = Date().timeIntervalSince(canceledAt)
        try check(m.phase == .failed && !m.canExport, "canceled refresh must retain stale results without export")
        try check(Set(m.differences.map(\.table)).count == 1001, "cancel must retain prior content")
        try check(cancelTime < 5, "cancel took \(cancelTime)s")
        print(String(format: "PASS performance: 1001 tables/side (wide table 250 columns), initial %.2fs, refresh %.2fs, cancel %.3fs, main-runloop max gap %.3fs, ticks %d; native list scroll %.3fs", elapsed, refreshed, cancelTime, maximumPause, ticks, scrollTime))
    }

    @MainActor static func drivers() async throws {
        let name = env["QC_REGRESSION_DRIVER"]!
        let type = DatabaseType(rawValue: env["QC_REGRESSION_TYPE"]!)!
        try await activate(name)
        let db = env["QC_REGRESSION_DATABASE"]!
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: configuration(
            Int(env["QC_SCHEMA_TEST_PORT"]!)!, database: db, user: type == .postgresql ? "postgres" : "root", type: type))
        do {
            try await session.connect()
            try check(await session.isConnected(), "\(name) not connected")
            let databases = try await session.fetchDatabases()
            try check(databases.contains(db), "\(name) database list")
            if type == .redis {
                guard let redis = session as? any RedisWorkspaceSession else { throw RegressionFailure(description: "Redis protocol missing") }
                let page = try await redis.scanRedisKeys(databaseIndex: 0, cursor: 0, pattern: "qc_schema_*", count: 100)
                try check(page.keys.count == 1, "Redis key list")
                let detail = try await redis.fetchRedisKey(page.keys[0], maximumElements: 10)
                try check(detail.reference.name == "qc_schema_smoke", "Redis key inspector")
                let command = try await redis.executeRedisCommand(.init(source: "GET qc_schema_smoke", arguments: ["GET", "qc_schema_smoke"]), databaseIndex: 0)
                try check(command.reply == .bulkString("回归验证"), "Redis console result")
            } else {
                let objects = try await session.fetchObjects(in: db)
                guard let object = objects.first(where: { $0.name.hasSuffix("qc_schema_smoke") }) else {
                    throw RegressionFailure(description: "\(name) object inventory: \(objects.map(\.name))")
                }
                let detail = try await session.fetchDetails(for: object, in: db)
                try check(!detail.columns.isEmpty, "\(name) structure/inspector fields")
                let rows = Rows()
                let data = try await session.fetchDataPage(for: object, in: db, offset: 0, limit: 10, sort: .none, onBatch: { await rows.append($0) })
                let fetchedRows = await rows.values
                try check(!data.columns.isEmpty && !fetchedRows.isEmpty, "\(name) data page")
                if [.mysql, .postgresql, .doris].contains(type) {
                    let results = Rows()
                    let output = try await session.executeReadOnlyQuery("SELECT id AS alias_id, note, 1 + 1 AS expression FROM qc_schema_smoke", database: db, onBatch: { await results.append($0) })
                    let queryRows = await results.values
                    try check(output.columns.count == 3 && queryRows.count == 1, "\(name) SQL result")
                    let empty = Rows()
                    _ = try await session.executeReadOnlyQuery("SELECT * FROM qc_schema_smoke WHERE 1=0", database: db, onBatch: { await empty.append($0) })
                    try check(await empty.values.isEmpty, "\(name) empty SQL result")
                }
                // Build the shared native data grid from the actual driver response.
                let page = WorkspaceDatabaseDataPage(columns: data.columns, rows: await rows.values, offset: 0, limit: 10, hasNextPage: data.hasNextPage)
                let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in })
                let scroll = coordinator.makeScrollView()
                try check((scroll.documentView as? NSTableView)?.numberOfRows == page.rows.count, "\(name) native grid row count")
            }
            await session.close()
            try check(!(await session.isConnected()), "\(name) connection cleanup")
            print("PASS \(name): API 5 dynamic plugin, real connection/catalog/details/data, native grid or key inspector, query/console and close")
        } catch { await session.close(); throw error }
    }

    @MainActor static func previews(_ port: Int) async throws {
        let m = await model(port)
        m.compare(); await m.waitForComparison()
        try check(m.phase == .ready, m.errorMessage ?? "preview comparison")
        m.selectAdditions()
        m.focusedID = m.differences.first { $0.object == "column:note" }?.id
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else {
            throw RegressionFailure(description: "preview window")
        }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 940, height: 640))
            try await settle(view)
            try render(view, to: "native-" + (dark ? "dark" : "light") + ".png")
        }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1120, height: 720))
        try await settle(view)
        try render(view, to: "native-default.png")
        if let frame = view.superview {
            frame.wantsLayer = true
            try await settle(frame)
            try render(frame, to: "native-window.png")
        }
        print("PASS minimum-size light/dark native previews")
    }

    @MainActor static func connections(_ port: Int) async throws {
        let profiles = [("01 source", "qc_source"), ("02 target", "qc_target")].map { name, user in
            ConnectionProfile(id: UUID(), name: name, groupID: nil, host: "127.0.0.1", port: port,
                username: user, defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: .now)
        }
        let m = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: profiles), credentials: InMemoryCredentialStore())
        await m.loadProfiles()
        let controller = WorkspaceSchemaComparisonWindowController(model: m)
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "setup window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([window])
        defer { window.orderOut(nil); window.close() }
        try await settle(view)
        let sheet = window
        let content = view
        let source = try popup("schemaComparisonSource", in: content)
        let target = try popup("schemaComparisonTarget", in: content)
        let sourceDB = try combo("schemaComparisonSourceDatabase", in: content)
        let targetDB = try combo("schemaComparisonTargetDatabase", in: content)
        try check(source.numberOfItems == 3 && target.numberOfItems == 3, "both saved connections must be listed")
        try await waitFor(sourceDB, contains: "qc_schema_source", excludes: "qc_schema_target")
        try await waitFor(targetDB, contains: "qc_schema_target", excludes: "qc_schema_source")
        try check(!enabled(try element("schemaComparisonConnectionsCompare", in: sheet)), "empty databases must disable Compare")
        source.selectItem(at: 2); source.sendAction(source.action, to: source.target)
        try await waitFor(sourceDB, contains: "qc_schema_target", excludes: "qc_schema_source")
        source.selectItem(at: 1); source.sendAction(source.action, to: source.target)
        try await waitFor(sourceDB, contains: "qc_schema_source", excludes: "qc_schema_target")
        target.selectItem(at: 1); target.sendAction(target.action, to: target.target)
        try await waitFor(targetDB, contains: "qc_schema_source", excludes: "qc_schema_target")
        target.selectItem(at: 2); target.sendAction(target.action, to: target.target)
        try await waitFor(targetDB, contains: "qc_schema_target", excludes: "qc_schema_source")
        sourceDB.selectItem(withObjectValue: "qc_schema_source"); sourceDB.sendAction(sourceDB.action, to: sourceDB.target)
        targetDB.selectItem(withObjectValue: "qc_schema_target"); targetDB.sendAction(targetDB.action, to: targetDB.target)
        try await settle(content)
        try check(enabled(try element("schemaComparisonConnectionsCompare", in: sheet)), "choosing discovered databases must enable Compare")
        try check(m.source.database.isEmpty && m.target.database.isEmpty, "setup leaked edits before confirmation")
        for dark in [false, true] {
            sheet.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(content)
            try render(content, to: "connection-picker-" + (dark ? "dark" : "light") + ".png")
            try await captureWindow(sheet, filename: "setup-window-" + (dark ? "dark" : "light") + ".png")
        }
        try await press("schemaComparisonOptions", in: sheet); try await settle(content)
        guard let optionSheet = sheet.attachedSheet, let optionContent = optionSheet.contentView else { throw RegressionFailure(description: "options sheet") }
        try render(optionContent, to: "comparison-options.png")
        try await press("schemaComparisonOptionsDone", in: optionSheet); try await settle(content)
        try await press("schemaComparisonConnectionsCancel", in: sheet)
        try check(!window.isVisible && m.source.database.isEmpty && m.target.database.isEmpty && m.phase == .idle, "Cancel must discard database selection and close initial setup")
        let nextModel = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: profiles), credentials: InMemoryCredentialStore(), snapshotLoader: NativeFlowSnapshotLoader())
        await nextModel.loadProfiles()
        let nextController = WorkspaceSchemaComparisonWindowController(model: nextModel)
        guard let next = nextController.window, let nextContent = next.contentView else { throw RegressionFailure(description: "second setup") }
        next.setFrameOrigin(NSPoint(x: -10000, y: -10000)); next.orderBack(nil)
        next.setAccessibilityElement(true); next.setAccessibilityRole(.window); NSApp.setAccessibilityWindows([next])
        defer { next.orderOut(nil); next.close() }
        try await settle(nextContent)
        try await press("schemaComparisonSwap", in: next); try await settle(nextContent)
        let swapped = try popup("schemaComparisonSource", in: nextContent)
        try check(swapped.indexOfSelectedItem == 2, "Swap did not update native connection popup")
        try await press("schemaComparisonSwap", in: next); try await settle(nextContent)
        let first = try combo("schemaComparisonSourceDatabase", in: nextContent)
        let second = try combo("schemaComparisonTargetDatabase", in: nextContent)
        try await waitFor(first, contains: "qc_schema_source", excludes: "qc_schema_target")
        try await waitFor(second, contains: "qc_schema_target", excludes: "qc_schema_source")
        first.selectItem(withObjectValue: "qc_schema_source"); first.sendAction(first.action, to: first.target)
        second.selectItem(withObjectValue: "qc_schema_target"); second.sendAction(second.action, to: second.target)
        try await settle(nextContent)
        try await press("schemaComparisonChooseTables", in: next)
        for _ in 0..<100 {
            if descendants(nextContent).compactMap({ $0 as? NSTableView }).contains(where: { $0.numberOfRows > 0 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle(nextContent)
        try await captureWindow(next, filename: "table-scope-unselected-window.png")
        print("CATALOG_ROWS", descendants(nextContent).compactMap { ($0 as? NSTableView)?.numberOfRows })
        print("DIRECT_TABLES", try await nextModel.makeEndpointDraft(.init(profileID: profiles[0].id, database: "qc_schema_source")).tableNames())
        try check(!enabled(try element("schemaComparisonConnectionsCompare", in: next)), "explicit empty table scope must disable Next")
        try await press("schemaComparisonTable:orders", in: next); try await settle(nextContent)
        try check(enabled(try element("schemaComparisonConnectionsCompare", in: next)), "choosing an actual source table must enable Next")
        try render(nextContent, to: "table-scope.png")
        try await captureWindow(next, filename: "table-scope-window.png")
        try await press("schemaComparisonIgnoreComments", in: next)
        try await press("schemaComparisonOptions", in: next); try await settle(nextContent)
        guard let scopeSheet = next.attachedSheet else { throw RegressionFailure(description: "scope options") }
        guard let scopeContent = scopeSheet.contentView else { throw RegressionFailure(description: "scope content") }
        let pattern = try nativeTextField("schemaComparisonIncludedTables", in: scopeContent)
        try check(scopeSheet.makeFirstResponder(pattern), "scope pattern first responder")
        guard let editor = pattern.currentEditor() as? NSTextView else { throw RegressionFailure(description: "scope pattern editor") }
        editor.string = "orders"; editor.didChangeText()
        try await settle(scopeContent)
        try await press("schemaComparisonOptionsDone", in: scopeSheet); try await settle(nextContent)
        try await press("schemaComparisonConnectionsCompare", in: next)
        try await settle(nextContent)
        try check(nextModel.phase == .loading && next.attachedSheet == nil, "Next must show the independent reading page")
        try await captureWindow(next, filename: "reading-window.png")
        await nextModel.waitForComparison(); try await settle(nextContent)
        try check(nextModel.phase == .ready, nextModel.errorMessage ?? "selected connections failed comparison")
        try check(nextModel.source.profileID == profiles[0].id && nextModel.target.profileID == profiles[1].id, "wrong committed profile IDs")
        try check(nextModel.source.database == "qc_schema_source" && nextModel.target.database == "qc_schema_target", "wrong committed databases")
        try check(nextModel.options.ignoresComments && nextModel.options.includedTables == "orders", "setup options were not committed: ignore=\(nextModel.options.ignoresComments), include=\(nextModel.options.includedTables)")
        try check(nextModel.options.selectedTables == ["orders"], "native table selection was not committed")
        try check(nextModel.differences.allSatisfy { $0.table == "orders" }, "table range was ignored")
        nextModel.selectAdditions()
        try check(nextModel.selectedDifferences.count == 2, "selected restricted connections did not produce expected differences")
        try render(nextContent, to: "flow-differences.png")
        try await captureWindow(next, filename: "differences-window.png")
        try await press("schemaComparisonPreview", in: next); try await settle(nextContent)
        try check(next.attachedSheet == nil, "SQL review must replace the page, not open a sheet")
        _ = try element("schemaComparisonReviewObjects", in: next)
        try render(nextContent, to: "flow-sql-review.png")
        try await captureWindow(next, filename: "review-window.png")
        try await press("schemaComparisonPreviewDone", in: next)
        try check(nextModel.selectedDifferences.count == 2, "Back from review lost selected changes")
        try await press("schemaComparisonPrevious", in: next); try await settle(nextContent)
        try check(next.attachedSheet == nil, "Back must replace differences with setup")
        _ = try popup("schemaComparisonSource", in: nextContent)
        try await press("schemaComparisonConnectionsCompare", in: next); try await settle(nextContent)
        try check(nextModel.selectedDifferences.count == 2, "unchanged setup Next discarded selected changes")
        print("PASS connection setup: both native popup actions switch independent restricted users; actual database discovery follows each user; native combo selection, empty-state gating, cancel, reopen, swap, commit and real schema comparison; no business connections or desktop input")
    }

    @MainActor static func popup(_ id: String, in view: NSView) throws -> NSPopUpButton {
        guard let control = descendants(view).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityIdentifier() == id }) else {
            throw RegressionFailure(description: "native connection popup missing: " + id)
        }
        return control
    }
    @MainActor static func combo(_ id: String, in view: NSView) throws -> NSComboBox {
        guard let control = descendants(view).compactMap({ $0 as? NSComboBox }).first(where: { $0.accessibilityIdentifier() == id }) else {
            throw RegressionFailure(description: "native database combo missing: " + id)
        }
        return control
    }
    @MainActor static func waitFor(_ combo: NSComboBox, contains required: String, excludes absent: String) async throws {
        for _ in 0..<150 {
            let names = combo.objectValues.compactMap { $0 as? String }
            if names.contains(required) && !names.contains(absent) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RegressionFailure(description: "database list did not match selected connection: " + String(describing: combo.objectValues))
    }

    @MainActor static func native(_ port: Int) async throws {
        let m = await model(port)
        let board = NSPasteboard(name: .init("qc-schema-regression-" + UUID().uuidString))
        let exportURL = URL(fileURLWithPath: env["QC_REGRESSION_OUTPUT"]!).appending(path: "native-" + UUID().uuidString + ".sql")
        let controller = WorkspaceSchemaComparisonWindowController(model: m, pasteboard: board, makeSavePanel: {
            let panel = NSSavePanel()
            panel.directoryURL = exportURL.deletingLastPathComponent()
            panel.nameFieldStringValue = exportURL.lastPathComponent
            return panel
        })
        guard let window = controller.window, let view = window.contentView else { throw RegressionFailure(description: "native window") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close(); board.releaseGlobally() }
        // Explicitly register the isolated window: an accessory process with no
        // activated window can otherwise publish AXWindows as the app itself.
        window.setAccessibilityElement(true)
        window.setAccessibilityRole(.window)
        NSApp.setAccessibilityWindows([window])
        try await settle(view)
        let originalSize = view.bounds.size
        let originalFrame = window.frame
        try await press("schemaComparisonConnectionsCompare", in: window)
        await Task.yield()
        try check(m.phase == .loading || m.phase == .ready, "initial setup did not begin comparison")
        try check(window.attachedSheet == nil, "reading must be a separate page")
        await m.waitForComparison(); try await settle(view)
        try check(m.phase == .ready && window.frame == originalFrame && window.toolbar != nil,
                  "step transition resized window or omitted toolbar: old=\(originalFrame), new=\(window.frame), content old=\(originalSize), new=\(view.bounds.size)")
        let comparisonSize = view.bounds.size
        let sourceBeforeEditing = m.source
        let targetBeforeEditing = m.target
        let resultsBeforeEditing = m.differences
        try await press("schemaComparisonConfigure", in: window); try await settle(view)
        try check(window.attachedSheet == nil, "setup must be a separate page, not a sheet")
        let connections = window
        let connectionView = view
        try render(connectionView, to: "native-connections.png")
        try await press("schemaComparisonSourceDatabase", in: connections, value: "cancelled_draft")
        try await settle(connectionView)
        try await press("schemaComparisonSwap", in: connections); try await settle(connectionView)
        try await press("schemaComparisonConnectionsCancel", in: connections); try await settle(view)
        try check(window.attachedSheet == nil && m.source == sourceBeforeEditing && m.target == targetBeforeEditing
                  && m.differences == resultsBeforeEditing && m.phase == .ready, "cancelled draft changed current comparison")
        try await press("schemaComparisonSelectAdditions", in: window); try await settle(view)
        guard let outline = descendants(view).compactMap({ $0 as? NSOutlineView }).first else {
            throw RegressionFailure(description: "native three-column comparison outline missing")
        }
        try check(outline.tableColumns.map { $0.identifier.rawValue } == ["source", "action", "target"], "comparison columns do not match source/action/target")
        if let checkbox = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "note" }) {
            checkbox.performClick(nil); try await settle(view)
            try check(m.selectedDifferences.count == m.differences.filter { $0.sqlForReview != nil }.count - 1, "native outline checkbox did not deselect")
            checkbox.performClick(nil); try await settle(view)
        } else { throw RegressionFailure(description: "native outline column checkbox missing") }
        try check(m.selectedDifferences.count == m.differences.filter { $0.sqlForReview != nil }.count, "native select changes: selected=\(m.selectedDifferences.count), eligible=\(m.differences.filter { $0.sql != nil }.count), phase=\(m.phase)")
        let selected = m.selectedIDs
        try editSearch("note", window: window, view: view)
        try await settle(view)
        try check(m.visibleDifferences.count == 1, "native search field binding: query=\(m.search), count=\(m.visibleDifferences.count)")
        try editSearch("", window: window, view: view)
        try await settle(view)
        try await press("schemaComparisonShowEqual", in: window); try await settle(view)
        try check(m.showsEqual, "show equal checkbox")
        guard let table = descendants(view).compactMap({ $0 as? NSTableView }).first else {
            throw RegressionFailure(description: "native difference list")
        }
        // Section headers are native rows; select the first actual object row.
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await settle(view)
        try check(m.focusedID != nil, "native row selection")
        guard let segmented = descendants(view).compactMap({ $0 as? NSSegmentedControl }).first else {
            throw RegressionFailure(description: "detail mode picker")
        }
        for segment in [1, 2, 3, 0] {
            segmented.selectedSegment = segment
            segmented.sendAction(segmented.action, to: segmented.target)
            try await settle(view)
        }
        try await press("schemaComparisonPreview", in: window); try await settle(view)
        try check(window.attachedSheet == nil, "review must be a full page")
        try check(window.frame == originalFrame, "review page resized the window")
        _ = try element("schemaComparisonReviewObjects", in: window)
        let preview = window
        if m.selectedDifferences.contains(where: \.needsDestructiveReview) {
            try check(!enabled(try element("schemaComparisonPreviewExport", in: preview)), "destructive SQL must require review")
            try await press("schemaComparisonReviewAcknowledgment", in: preview)
        }
        try await press("schemaComparisonCopy", in: preview)
        try check(board.string(forType: .string) == m.selectedDifferences.compactMap(\.sqlForReview).joined(separator: "\n\n"), "copy did not preserve displayed SQL")
        guard let reviewTable = descendants(view).compactMap({ $0 as? NSTableView }).first else {
            throw RegressionFailure(description: "review objects list missing")
        }
        reviewTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle(view)
        try await press("schemaComparisonCopy", in: preview)
        try check(Set(m.selectedDifferences.compactMap(\.sqlForReview)).contains(board.string(forType: .string) ?? ""), "individual review selection did not change displayed/copied SQL")
        reviewTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await settle(view)
        try await press("schemaComparisonPreviewExport", in: window)
        for _ in 0..<300 {
            if window.attachedSheet is NSSavePanel { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle(view)
        guard let canceled = window.attachedSheet as? NSSavePanel else { throw RegressionFailure(description: "export must use document-modal save panel") }
        canceled.cancel(nil); try await settle(view)
        try check(window.attachedSheet == nil && m.selectedIDs == selected, "canceling export changed selection")
        try await press("schemaComparisonPreviewExport", in: window)
        for _ in 0..<300 {
            if window.attachedSheet is NSSavePanel { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle(view)
        guard let save = window.attachedSheet as? NSSavePanel else { throw RegressionFailure(description: "second save panel") }
        let url = exportURL
        try check(save.url?.standardizedFileURL == url.standardizedFileURL,
                  "save panel destination mismatch: \(String(describing: save.url))")
        // Complete the native sheet through AppKit; no keyboard or pointer input.
        window.endSheet(save, returnCode: .OK)
        save.orderOut(nil)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(FileManager.default.fileExists(atPath: url.path), "save did not finish; panel URL=\(String(describing: save.url)), visible=\(save.isVisible), attached=\(window.attachedSheet != nil)")
        try check(try String(contentsOf: url, encoding: .utf8) == m.script, "native save did not preserve SQL")
        try await press("schemaComparisonPreviewDone", in: preview); try await settle(view)
        try check(window.attachedSheet == nil && m.selectedIDs == selected, "Back from review lost selection")
        try check(window.frame == originalFrame, "Back from review resized the window")
        let focus = m.focusedID
        try await press("schemaComparisonRefresh", in: window)
        try check(m.selectedIDs == selected && view.bounds.size == comparisonSize && !m.canExport, "refresh lost content or enabled stale export")
        await m.waitForComparison(); try await settle(view)
        try check(m.selectedIDs == selected && m.focusedID == focus, "refresh lost selection/focus")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 940, height: 640))
            try await settle(view)
            try check(enabled(try element("schemaComparisonPreview", in: window)), "narrow window preview unavailable")
            try render(view, to: "native-" + (dark ? "dark" : "light") + ".png")
        }
        let oldSource = m.source
        try await press("schemaComparisonConfigure", in: window); try await settle(view)
        try check(window.attachedSheet == nil, "reopened setup must be a page")
        let secondSetup = window
        try await press("schemaComparisonSwap", in: secondSetup)
        try await press("schemaComparisonConnectionsCompare", in: secondSetup)
        try check(m.target == oldSource && !m.canExport, "committed swap must invalidate old comparison")
        await m.waitForComparison(); try await settle(view)
        try check(m.phase == .ready && m.selectedIDs.isEmpty, "swapped comparison must finish without stale selection")
        window.close()
        try check(m.phase == .idle && m.script.isEmpty, "native window close invalidation")
        let nextModel = await model(port)
        let next = WorkspaceSchemaComparisonWindowController(model: nextModel, pasteboard: board)
        next.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); next.window?.orderBack(nil)
        try check(nextModel.phase == .idle && nextModel.selectedIDs.isEmpty, "reopened window reused stale data")
        next.window?.close()
        print("PASS native controls: toolbar compare/swap, checkbox/search/selection, three detail modes, preview/copy, save/cancel, refresh stability, 940px light/dark layout and close/reopen; no desktop input")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func editSearch(_ value: String, window: NSWindow, view: NSView) throws {
        let field = try nativeTextField("schemaComparisonSearch", in: view)
        try check(window.makeFirstResponder(field), "search first responder")
        guard let editor = field.currentEditor() as? NSTextView else { throw RegressionFailure(description: "search field editor") }
        editor.string = value
        editor.didChangeText()
    }
    @MainActor static func nativeTextField(_ id: String, in view: NSView) throws -> NSTextField {
        guard let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == id || (id == "schemaComparisonSearch" && ["Find Table or Field", "查找表或字段"].contains($0.placeholderString ?? "")) || (id == "schemaComparisonIncludedTables" && $0.placeholderString == "orders*, users") }) else {
            throw RegressionFailure(description: "text field missing: " + id)
        }
        return field
    }
    @MainActor static func element(_ id: String, in root: Any) throws -> NSObject {
        guard let result = elements(root).first(where: { attribute($0, "accessibilityIdentifier") as? String == id }) else {
            dumpAX(root, level: 0)
            throw RegressionFailure(description: "AX control missing: " + id)
        }
        return result
    }
    @MainActor static func enabled(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }
    @MainActor static func press(_ id: String, in root: Any, value: String? = nil) async throws {
        if !id.hasPrefix("label:") && !id.hasPrefix("schemaComparisonTable:") { _ = try element(id, in: root) }
        FileHandle.standardError.write(Data(("BEGIN AX " + id + "\n").utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "schema-comparison-accessibility")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), id] + (value.map { [$0] } ?? [])
        let errors = Pipe(); process.standardError = errors
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 || (finished.terminationStatus == 5 && id.contains("Export")) {
                    FileHandle.standardError.write(Data(("END AX " + id + "\n").utf8))
                    continuation.resume()
                }
                else {
                    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: RegressionFailure(description: message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
    /// Optional compositor capture includes native Glass. Targets only this probe's
    /// offscreen window; never captures the desktop or sends input events.
    @MainActor static func captureWindow(_ window: NSWindow, filename: String) async throws {
        guard env["QC_SCHEMA_WINDOW_CAPTURE"] == "1" else { return }
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP compositor capture: screen recording permission unavailable; no permission prompt requested")
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw RegressionFailure(description: "probe window unavailable for compositor capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RegressionFailure(description: "compositor PNG") }
        try data.write(to: URL(fileURLWithPath: env["QC_REGRESSION_OUTPUT"]!).appending(path: filename))
    }

    @MainActor static func render(_ view: NSView, to filename: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = view.layer else { throw RegressionFailure(description: "render unavailable") }
        let cg = context.cgContext
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        cg.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        if view.isFlipped {
            cg.translateBy(x: 0, y: view.bounds.height); cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RegressionFailure(description: "PNG unavailable") }
        try data.write(to: URL(fileURLWithPath: env["QC_REGRESSION_OUTPUT"]!).appending(path: filename))
    }
    @MainActor static func settle(_ view: NSView) async throws {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    @MainActor static func attribute(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) -> [NSObject] {
            guard depth < 24, let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result = [object]
            for name in ["accessibilityChildren", "accessibilityRows"] {
                for child in attribute(object, name) as? [Any] ?? [] {
                    result += visit(child, depth: depth + 1)
                }
            }
            return result
        }
        return visit(value, depth: depth)
    }
    @MainActor static func dumpAX(_ value: Any, level: Int) {
        for object in elements(value) {
            print("\(attribute(object, "accessibilityRole") ?? "?" as NSString) id=\(attribute(object, "accessibilityIdentifier") ?? "" as NSString) label=\(attribute(object, "accessibilityLabel") ?? "" as NSString)")
        }
    }
}
