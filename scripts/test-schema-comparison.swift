import AppKit
import Foundation
@testable import QueryCraftFeature

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Run against the disposable fixture documented in test-schema-comparison.py.
/// This executable only reads databases and exports a local SQL file.
@main
struct SchemaComparisonSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw CheckFailure(description: message) }
        }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["QC_SCHEMA_TEST_DRIVER"], let bundle = Bundle(path: path),
              let port = env["QC_SCHEMA_TEST_PORT"].flatMap(Int.init),
              let directory = env["QC_SCHEMA_TEST_PREVIEW"] else {
            throw CheckFailure(description: "Set QC_SCHEMA_TEST_DRIVER, QC_SCHEMA_TEST_PORT and QC_SCHEMA_TEST_PREVIEW")
        }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
            throw CheckFailure(description: "Dynamic driver entry unavailable")
        }
        try await entry.init().activate()
        func profile(_ name: String, database: String) -> ConnectionProfile {
            .init(id: UUID(), name: name, groupID: nil, host: "127.0.0.1", port: port,
                  username: "root", defaultDatabase: database, tlsMode: .disabled,
                  storesCredential: false, createdAt: .now)
        }
        let model = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: [
            profile("01 source", database: "qc_schema_source"), profile("02 target", database: "qc_schema_target")
        ]), credentials: InMemoryCredentialStore())
        await model.loadProfiles()
        model.compare()
        await model.waitForComparison()
        try check(model.phase == .ready, model.errorMessage ?? "Comparison did not finish")
        try check(model.differences.contains { $0.table == "orders" && $0.object == "column:note" && $0.status == .added }, "Missing added column")
        try check(model.differences.contains { $0.table == "users" && $0.status == .modified }, "Missing modified column")
        try check(model.differences.contains { $0.table == "legacy_events" && $0.status == .targetOnly }, "Missing target-only table")
        try check(model.selectedIDs.isEmpty, "Unexpected default selection")
        model.selectAdditions()
        try check(model.selectedDifferences.count == 2, "Expected exactly two exportable additions")
        try check(model.script.contains("`qc_schema_target`.`orders`"), "Wrong target")
        try check(model.script.contains("买家备注"), "Column comment encoding changed")
        try check(!model.script.contains("DROP TABLE") && !model.script.contains("MODIFY"), "Unexpected destructive SQL")
        model.focusedID = model.differences.first { $0.object == "column:note" }?.id

        let controller = WorkspaceSchemaComparisonWindowController(model: model)
        guard let window = controller.window, let view = window.contentView else {
            throw CheckFailure(description: "Native window unavailable")
        }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.orderBack(nil)
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        try check(window.toolbar != nil, "Native toolbar missing")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try model.script.write(to: URL(fileURLWithPath: directory).appending(path: "schema-sync.sql"), atomically: true, encoding: .utf8)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CheckFailure(description: "Offscreen bitmap unavailable")
        }
        if let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = view.layer {
            context.cgContext.saveGState()
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                     y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            context.cgContext.translateBy(x: 0, y: view.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: context.cgContext)
            context.cgContext.restoreGState()
        } else {
            throw CheckFailure(description: "Offscreen layer unavailable")
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Offscreen PNG unavailable")
        }
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "schema-comparison-native.png"))
        window.orderOut(nil)
        window.close()
        print("PASS: installed MySQL driver, real snapshots/differences, two additive statements, native toolbar and offscreen render")
    }
}
