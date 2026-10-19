import AppKit
import SwiftUI
import ScreenCaptureKit
import CodeEditTextView
import Foundation
@testable import QueryCraftFeature

private struct Failure: Error, CustomStringConvertible { let description: String }
private struct NativeSlowCatalogLoader: SchemaComparisonSnapshotLoading {
    let base: SchemaComparisonCatalogLoader
    func load(configuration: DatabaseConnectionConfiguration, progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        try await base.load(configuration: configuration) { event in
            await progress(event)
            try? await Task.sleep(for: .milliseconds(90))
        }
    }
}
@MainActor private final class NativeProbeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct NativeFullRegression {
    static let env = ProcessInfo.processInfo.environment
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = NativeProbeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do {
                try await run()
                if let path = env["QC_REGRESSION_STATUS"] { try "PASS".write(toFile: path, atomically: true, encoding: .utf8) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                if let path = env["QC_REGRESSION_STATUS"] { try? "FAIL \(error)".write(toFile: path, atomically: true, encoding: .utf8) }
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func config(_ port: Int, _ db: String) -> DatabaseConnectionConfiguration {
        .init(databaseType: .mysql, host: "127.0.0.1", port: port, authentication: .usernamePassword(username: "root", password: nil), database: db, tlsMode: .disabled)
    }
    @MainActor static func run() async throws {
        let driver = env["QC_REGRESSION_DRIVERS"]! + "/MySQL-\(env["QC_REGRESSION_ARCH"]!).querycraftdriver"
        guard let bundle = Bundle(path: driver) else { throw Failure(description: "driver missing") }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw Failure(description: "driver identity") }
        try await entry.init().activate()
        let sourcePort = Int(env["QC_SCHEMA_TEST_PORT"]!)!, targetPort = Int(env["QC_SCHEMA_TARGET_PORT"]!)!
        let options = SchemaComparisonOptions(enableRollback: true)
        let factory = DefaultWorkspaceSessionFactory()
        let loader = SchemaComparisonCatalogLoader(sessionFactory: factory, options: options)
        let sc = config(sourcePort, "qc_schema_source"), tc = config(targetPort, "qc_schema_target")
        let source = try await loader.load(configuration: sc) { _ in }
        let target = try await loader.load(configuration: tc) { _ in }
        // A database-wide read-only account may compare supported metadata
        // after explicitly excluding inaccessible routines and triggers. A
        // table-only grant cannot prove that missing objects are absent.
        var readOptions = options; readOptions.functions = false; readOptions.triggers = false
        let readerConfig = DatabaseConnectionConfiguration(databaseType: .mysql, host: "127.0.0.1", port: sourcePort, authentication: .usernamePassword(username: "qc_reader", password: nil), database: "qc_schema_source", tlsMode: .disabled)
        let readerLoader = SchemaComparisonCatalogLoader(sessionFactory: factory, options: readOptions)
        let readable = try await readerLoader.load(configuration: readerConfig) { _ in }
        try check(readable.objects.count == source.objects.count, "read-only catalog was truncated")
        let tableConfig = DatabaseConnectionConfiguration(databaseType: .mysql, host: "127.0.0.1", port: sourcePort, authentication: .usernamePassword(username: "qc_table_reader", password: nil), database: "qc_schema_source", tlsMode: .disabled)
        var rejectedPartialCatalog = false
        do { _ = try await readerLoader.load(configuration: tableConfig) { _ in } }
        catch let error as SchemaEngineFailure { rejectedPartialCatalog = error.localizedDescription.contains("SELECT") }
        try check(rejectedPartialCatalog, "table-only visibility did not reject incomplete catalog")
        let result = try await SchemaComparisonNativeEngine().analyze(source: source, target: target, options: options)
        try check(result.differences.contains { $0.object.hasPrefix("foreignKey:") }, "foreign-key diff missing")
        try check(result.differences.contains { $0.object == "view" }, "view diff missing")
        try check(result.differences.contains { $0.object == "function" }, "routine diff missing")
        try check(result.differences.contains { $0.object.hasPrefix("trigger:") }, "trigger diff missing")
        try check(result.plan.rollbackComplete && !result.plan.rollbackStatements.isEmpty, "rollback plan missing")
        let out = URL(fileURLWithPath: env["QC_REGRESSION_OUTPUT"]!)
        try result.plan.sql.write(to: out.appendingPathComponent("forward.sql"), atomically: true, encoding: .utf8)
        try result.plan.rollbackSQL.write(to: out.appendingPathComponent("rollback.sql"), atomically: true, encoding: .utf8)
        let report = result.differences.filter { $0.status != .equal }.map { $0.table + " / " + $0.object + " / " + $0.status.rawValue }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("differences.txt"), atomically: true, encoding: .utf8)
        let selectedIDs = Set(result.differences.filter { $0.sqlForReview != nil }.map(\.id))
        let deployPlan = try await SchemaComparisonNativeEngine().plan(result: result.raw, selectedIDs: selectedIDs, ignoreForeignKeyChecks: true)
        try check(deployPlan.statements.first == "SET FOREIGN_KEY_CHECKS = 0" && deployPlan.statements.last == "SET FOREIGN_KEY_CHECKS = 1", "FK-check wrapper missing")
        let runner = SchemaComparisonDeployment(sessionFactory: factory)
        runner.start(statements: deployPlan.statements, sourceConfiguration: sc, targetConfiguration: tc, originalSource: source, originalTarget: target, options: options, selection: result.differences)
        await runner.wait()
        try check(runner.phase == .succeeded, "deploy: " + (runner.errorMessage ?? "unknown") + " SQL: " + (runner.records.last?.sql ?? "preflight"))
        let actual = try await loader.load(configuration: tc) { _ in }
        let remaining = try await SchemaComparisonNativeEngine().analyze(source: source, target: actual, options: options)
        try check(remaining.differences.allSatisfy { $0.status == .equal }, "did not converge: " + remaining.differences.filter { $0.status != .equal }.map { $0.table + "." + $0.object + ":" + $0.changeSummary }.joined(separator: "; "))
        runner.start(statements: deployPlan.rollbackStatements, sourceConfiguration: sc, targetConfiguration: tc, originalSource: source, originalTarget: target, options: options, rollback: true, selection: result.differences)
        await runner.wait()
        try check(runner.phase == .succeeded, "rollback: " + (runner.errorMessage ?? "unknown") + " SQL: " + (runner.records.last?.sql ?? "preflight"))
        let restored = try await loader.load(configuration: tc) { _ in }
        let originalReference = SchemaComparisonSnapshot(database: "qc_schema_target", serverID: "reference-only", version: target.version, sqlMode: target.sqlMode, lowerCaseTableNames: target.lowerCaseTableNames, objects: target.objects, capturedAt: target.capturedAt, engineMetadata: target.engineMetadata)
        let restoreDiff = try await SchemaComparisonNativeEngine().analyze(source: originalReference, target: restored, options: options)
        try check(restoreDiff.differences.allSatisfy { $0.status == .equal }, "rollback did not restore original structure: " + restoreDiff.differences.filter { $0.status != .equal }.map { $0.table + "." + $0.object }.joined(separator: ","))
        // Reject stale target before running the first statement.
        let session = await factory.makeSession(configuration: tc)
        try await session.connect()
        _ = try await session.executeStatement("ALTER TABLE `qc_schema_target`.`users` ADD COLUMN `concurrent_change` int", kind: .ddl(.alter), database: "qc_schema_target") { _ in }
        await session.close()
        let staleRunner = SchemaComparisonDeployment(sessionFactory: factory)
        staleRunner.start(statements: result.plan.statements, sourceConfiguration: sc, targetConfiguration: tc, originalSource: source, originalTarget: target, options: options)
        await staleRunner.wait()
        try check(staleRunner.phase == .failed && staleRunner.records.isEmpty, "stale target executed SQL")
        let profiles = [("Source", sourcePort, "qc_schema_source"), ("Target", targetPort, "qc_schema_target")].map { name, port, db in ConnectionProfile(id: UUID(), name: name, groupID: nil, host: "127.0.0.1", port: port, username: "root", defaultDatabase: db, tlsMode: .disabled, storesCredential: false, createdAt: .now) }
        let uiLoader: (any SchemaComparisonSnapshotLoading)? = env["QC_SCHEMA_SKIP_UI"] == "1" ? nil : NativeSlowCatalogLoader(base: loader)
        let model = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: profiles), credentials: InMemoryCredentialStore(), snapshotLoader: uiLoader)
        await model.loadProfiles(); model.options = options
        if env["QC_SCHEMA_SKIP_UI"] == "1" {
            model.compare(); await model.waitForComparison(); await model.waitForPlan()
            try check(model.phase == .ready && model.canExport, model.errorMessage ?? "native model")
            try check(model.nativePlan != nil && model.selectedIDs.count > 5, "native plan not used by model")
            model.close()
            print("PASS Swift native MySQL \(source.version) → \(target.version): \(report.count) changes; deploy, verified convergence, rollback, stale-plan rejection, read-only/partial grants, limited-session catalog, native model; UI deferred while desktop is locked")
            return
        }
        UserDefaults.standard.removeObject(forKey: "schemaComparison.resultsObjectFraction")
        let reviewPasteboard = NSPasteboard.withUniqueName()
        let controller = WorkspaceSchemaComparisonWindowController(model: model, pasteboard: reviewPasteboard)
        guard let window = controller.window, let view = window.contentView else { throw Failure(description: "window missing") }
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        window.setAccessibilityElement(true); window.setAccessibilityRole(.window)
        NSApp.setAccessibilityWindows([window])
        print("PROBE window", window.windowNumber, window.isVisible, window.frame, "app windows", NSApp.windows.count)
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let sourcePicker: NSPopUpButton = try control("schemaComparisonSource", in: view)
        try check(sourcePicker.numberOfItems == 3, "saved connections missing")
        sourcePicker.selectItem(at: 2); sourcePicker.sendAction(sourcePicker.action, to: sourcePicker.target)
        try await Task.sleep(for: .milliseconds(100))
        try check(sourcePicker.selectedItem?.representedObject as? String == profiles[1].id.uuidString, "native connection selection failed")
        sourcePicker.selectItem(at: 1); sourcePicker.sendAction(sourcePicker.action, to: sourcePicker.target)
        try await Task.sleep(for: .milliseconds(150))
        let sourceDatabase: NSComboBox = try control("schemaComparisonSourceDatabase", in: view)
        sourceDatabase.stringValue = "qc_schema_source"; sourceDatabase.sendAction(sourceDatabase.action, to: sourceDatabase.target)
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        try render(view, out.appendingPathComponent("setup-native.png"))
        try await capture(window, out.appendingPathComponent("setup-compositor.png"))
        let originalFrame = window.frame
        try await press("schemaComparisonConnectionsCompare")
        var progressIndicator: NSProgressIndicator?, progressFrame: NSRect?, samples = 0
        var previous = 0.0
        while model.phase == .loading {
            view.layoutSubtreeIfNeeded()
            if let indicator = descendants(view).compactMap({ $0 as? NSProgressIndicator }).first(where: { $0.accessibilityIdentifier() == "schemaComparisonReadingProgress" }) {
                let frame = indicator.convert(indicator.bounds, to: view)
                if let progressIndicator, let progressFrame {
                    try check(progressIndicator === indicator && progressFrame == frame && window.frame == originalFrame, "progress indicator or window moved")
                } else { progressIndicator = indicator; progressFrame = frame }
                try check(indicator.doubleValue >= previous, "progress moved backwards")
                previous = indicator.doubleValue; samples += 1
                if samples == 3 { try await capture(window, out.appendingPathComponent("reading-compositor.png")) }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.waitForComparison(); await model.waitForPlan()
        try check(samples >= 2, "slow-request progress was not exercised")
        try check(model.phase == .ready && model.canExport && model.nativePlan != nil, model.errorMessage ?? "native comparison failed")
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded()
        try check(window.frame == originalFrame, "page transition changed window frame")
        model.focusedID = "table:orders"
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        let ddlSplit: NSSplitView = try control("schemaComparisonDDLSplit", in: view)
        try check(ddlSplit.arrangedSubviews.count == 2 && abs(ddlSplit.arrangedSubviews[0].frame.width - ddlSplit.arrangedSubviews[1].frame.width) < 2, "initial DDL panes are unbalanced")
        try render(view, out.appendingPathComponent("differences-native.png"))
        try await capture(window, out.appendingPathComponent("differences-compositor.png"))
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
        let resultsSplit: NSSplitView = try control("schemaComparisonResultsSplit", in: view)
        let panes = resultsSplit.arrangedSubviews
        try check(panes.count == 2 && abs(panes[0].frame.height / (resultsSplit.bounds.height - resultsSplit.dividerThickness) - 0.6) < 0.02, "large window must retain a readable 60/40 split")
        for text in descendants(view).compactMap({ $0 as? NSTextView }).filter({ $0.accessibilityIdentifier().contains("DDL") }) {
            try check(!text.string.isEmpty && text.visibleRect.width > 200 && text.visibleRect.height > 30, "DDL text must have a visible reading area")
            if let scroll = text.enclosingScrollView, let ruler = scroll.verticalRulerView {
                try check(ruler.clipsToBounds, "line-number drawing must remain inside its native ruler")
                try check(text.convert(text.textContainerOrigin, to: scroll).x > ruler.frame.maxX, "DDL must begin after the line-number gutter")
            }
        }
        try await capture(window, out.appendingPathComponent("differences-large-compositor.png"))
        if let removed = model.differences.first(where: { $0.status == .targetOnly && $0.object == "table" }) {
            model.focusedID = removed.id
            try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
            let missing: NSTextField = try control("schemaComparisonSourceMissing", in: view)
            try check(!missing.isHidden, "missing source side must be explained")
            try await capture(window, out.appendingPathComponent("differences-missing-side.png"))
        } else { throw Failure(description: "removed table fixture missing") }
        model.focusedID = "table:orders"
        window.setContentSize(NSSize(width: 940, height: 560))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
            try await capture(window, out.appendingPathComponent("differences-narrow-\(dark ? "dark" : "light").png"))
        }
        window.appearance = NSAppearance(named: .aqua); window.setFrame(originalFrame, display: true)
        try await press("schemaComparisonPreview")
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        try render(view, out.appendingPathComponent("review-native.png"))
        try await capture(window, out.appendingPathComponent("review-compositor.png"))
        // Script actions are available directly; actual deployment still requires its native confirmation.
        try await press("schemaComparisonCopy")
        try check(reviewPasteboard.string(forType: .string) == model.script, "review copy should work before deployment confirmation")
        guard let reviewList = descendants(view).compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows > 2 }) else { throw Failure(description: "review list missing") }
        try check(reviewList.numberOfRows < model.selectedDifferences.count, "review must group column/index changes by database object")
        reviewList.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(250)); view.layoutSubtreeIfNeeded()
        guard let objectEditor = descendants(view).compactMap({ $0 as? CodeEditTextView.TextView }).first else { throw Failure(description: "object SQL missing") }
        try check(objectEditor.string.contains("new_child") && !objectEditor.string.contains("old_child"), "object review must project one group's SQL and dependencies")
        try await capture(window, out.appendingPathComponent("review-object-compositor.png"))
        reviewList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.setContentSize(NSSize(width: 1600, height: 960))
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded()
        try await capture(window, out.appendingPathComponent("review-large-compositor.png"))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
            guard let editor = descendants(view).compactMap({ $0 as? CodeEditTextView.TextView }).first else { throw Failure(description: "review editor missing") }
            guard let scroll = editor.enclosingScrollView else { throw Failure(description: "review scroll missing") }
            try check(!scroll.automaticallyAdjustsContentInsets, "embedded review must use local content insets")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await capture(window, out.appendingPathComponent("review-large-scrolled-\(dark ? "dark" : "light").png"))
        }
        window.appearance = NSAppearance(named: .aqua); window.setFrame(originalFrame, display: true)

        try await press("schemaComparisonDeploy")
        try await Task.sleep(for: .milliseconds(150))
        try await press("schemaComparisonConfirmDeploy")
        try await Task.sleep(for: .milliseconds(150))
        await model.deployment.wait()
        try check(model.deployment.phase == .succeeded, model.deployment.errorMessage ?? "native UI deployment")
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        try render(view, out.appendingPathComponent("deployment-native.png"))
        try await capture(window, out.appendingPathComponent("deployment-compositor.png"))
        try await press("schemaComparisonReviewRollback")
        try await Task.sleep(for: .milliseconds(120))
        try await press("schemaComparisonDeploy")
        try await Task.sleep(for: .milliseconds(120))
        try await press("schemaComparisonConfirmDeploy")
        try await Task.sleep(for: .milliseconds(120)); await model.deployment.wait()
        try check(model.deployment.phase == .succeeded && model.deployment.isRollback, model.deployment.errorMessage ?? "native UI rollback")
        try await capture(window, out.appendingPathComponent("rollback-compositor.png"))
        let optionsView = NSHostingView(rootView: SchemaComparisonOptionsView(options: options, apply: { _ in }, cancel: {}))
        optionsView.frame = NSRect(x: 0, y: 0, width: 780, height: 610)
        let optionWindow = NSWindow(contentRect: optionsView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        optionWindow.contentView = optionsView; optionWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000)); optionWindow.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200)); optionsView.layoutSubtreeIfNeeded()
        try render(optionsView, out.appendingPathComponent("options-native.png"))
        try await capture(optionWindow, out.appendingPathComponent("options-compositor.png"))
        optionWindow.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(180)); optionsView.layoutSubtreeIfNeeded()
        try await capture(optionWindow, out.appendingPathComponent("options-dark-compositor.png"))
        optionWindow.appearance = NSAppearance(named: .aqua)
        if let navigation = descendants(optionsView).compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows >= 4 }) {
            for (row, name) in [(1, "comparison"), (2, "filters"), (3, "advanced")] {
                navigation.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(180)); optionsView.layoutSubtreeIfNeeded()
                try await capture(optionWindow, out.appendingPathComponent("options-\(name)-compositor.png"))
            }
        } else { throw Failure(description: "native options navigation missing") }
        optionWindow.orderOut(nil); window.orderOut(nil); model.close()
        print("PASS Swift native MySQL \(source.version) → \(target.version): \(report.count) changes, \(result.plan.statements.count) forward statements; deploy/convergence/rollback/stale-preflight/native model")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func control<T: NSView>(_ id: String, in view: NSView) throws -> T {
        guard let result = descendants(view).first(where: { $0.accessibilityIdentifier() == id }) as? T else { throw Failure(description: "native control missing: " + id) }
        return result
    }
    @MainActor static func press(_ id: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("schema-comparison-accessibility")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), id]
        let errors = Pipe(); process.standardError = errors
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: Failure(description: id + ": " + String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!)) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
    @MainActor static func capture(_ window: NSWindow, _ url: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP compositor: no screen recording access"); return }
        let originalOrigin = window.frame.origin
        // WindowServer may decline an image for a window outside every display.
        // Keep this probe behind other apps, without activation or input events.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
            window.orderBack(nil)
        }
        defer { window.setFrameOrigin(originalOrigin) }
        try await Task.sleep(for: .milliseconds(120))
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { print("SKIP compositor: own window unavailable"); return }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width); config.height = Int(window.frame.height)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        } catch { print("SKIP optional compositor image: \(error)") }
    }
    @MainActor static func render(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = view.layer else { throw Failure(description: "render") }
        let cg = context.cgContext
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg.setFillColor(NSColor.windowBackgroundColor.cgColor); cg.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            cg.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            cg.translateBy(x: 0, y: view.bounds.height); cg.scaleBy(x: 1, y: -1); layer.render(in: cg)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "png") }
        try png.write(to: url)
    }
}
