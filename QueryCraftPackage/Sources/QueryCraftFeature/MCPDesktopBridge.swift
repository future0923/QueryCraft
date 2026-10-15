import AppKit
import Foundation
import MCP
import SwiftUI

struct MCPDesktopRequest: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let tool: String
    let profileID: UUID
    let database: String?
    let table: String?
    let objectKind: WorkspaceDatabaseObjectKind?
    let resultJSON: String?
}

enum MCPDesktopBridge {
    static let notification = Notification.Name("io.github.future0923.QueryCraft.MCPRequest")
    static func send(tool: String, profile: ConnectionProfile, database: String?, args: [String: Value], directory: URL) async throws -> Value {
        let identifier = directory.lastPathComponent == "QueryCraftDev" ? "io.github.future0923.QueryCraft.Dev" : "io.github.future0923.QueryCraft"
        let running = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty }
        guard running else { throw MCPFailure("Open QueryCraft to use desktop integration.") }
        let request = MCPDesktopRequest(id: UUID(), createdAt: Date(), tool: tool, profileID: profile.id,
            database: database, table: args.string("table"), objectKind: args.string("object_kind").flatMap(WorkspaceDatabaseObjectKind.init(rawValue:)), resultJSON: args.string("result_json"))
        let root = directory.appending(path: "MCPRequests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appending(path: request.id.uuidString + ".json")
        let response = root.appending(path: request.id.uuidString + ".response")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: response) }
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        DistributedNotificationCenter.default().postNotificationName(notification, object: request.id.uuidString, userInfo: nil, deliverImmediately: true)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let data = try? Data(contentsOf: response), let status = String(data: data, encoding: .utf8) {
                guard status == "opened" else { throw MCPFailure("QueryCraft could not open the requested content.") }
                return .object(["status": "opened"])
            }
        }
        throw MCPFailure("QueryCraft did not acknowledge the request. No query was retried.")
    }
}

@MainActor
final class MCPResultWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [MCPResultWindowController] = []
    static func show(_ json: String, profile: ConnectionProfile, database: String?) async throws {
        let value = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        let results = try await decodeResults(value)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "QueryCraft · MCP · " + profile.name
        window.minSize = NSSize(width: 600, height: 400)
        let controller = MCPResultWindowController(window: window)
        window.delegate = controller
        let truncated = value.objectValue?["results"]?.arrayValue?.contains {
            $0.objectValue?["result"]?.objectValue?["truncated"]?.boolValue == true
        } == true
        window.contentView = NSHostingView(rootView: MCPNativeResultView(results: results, database: database,
            type: profile.databaseType, truncated: truncated, dismiss: { [weak controller] in controller?.close() }))
        windows.append(controller)
        window.center(); controller.showWindow(nil)
    }
    func windowWillClose(_ notification: Foundation.Notification) { Self.windows.removeAll { $0 === self } }

    static func decodeResults(_ value: Value) async throws -> [WorkspaceStatementResult] {
        guard let entries = value.objectValue?["results"]?.arrayValue, !entries.isEmpty else { throw MCPFailure("Invalid MCP result.") }
        var results: [WorkspaceStatementResult] = []
        for (index, entry) in entries.enumerated() {
            guard let entry = entry.objectValue else { throw MCPFailure("Invalid statement result.") }
            let sql = entry["sql"]?.stringValue ?? ""
            let statement = SQLExecutionStatement(index: index, source: .init(revision: .init(1), text: sql),
                range: .init(location: 0, length: (sql as NSString).length), kind: .read)
            if let error = entry["error"]?.stringValue {
                results.append(.init(statement: statement, state: .failed(message: error, page: nil), elapsedSeconds: 0))
                continue
            }
            guard let result = entry["result"]?.objectValue,
                  let columnValues = result["columns"]?.arrayValue, let rowValues = result["rows"]?.arrayValue else { throw MCPFailure("Invalid table result.") }
            let columns = try columnValues.enumerated().map { index, value -> WorkspaceDatabaseDataColumn in
                guard let name = value.objectValue?["name"]?.stringValue else { throw MCPFailure("Invalid result column.") }
                return .init(id: index, name: name, type: value.objectValue?["type"]?.stringValue)
            }
            let rows = try rowValues.enumerated().map { index, value -> WorkspaceDatabaseDataRow in
                guard let cells = value.arrayValue, cells.count == columns.count else { throw MCPFailure("Invalid result row.") }
                return .init(id: index, values: cells.map { cell in
                    if cell == .null { return .null }
                    if let text = cell.stringValue { return .text(text) }
                    if let object = cell.objectValue {
                        if let text = object["text"]?.stringValue { return .text(text + (object["truncated"]?.boolValue == true ? "…" : "")) }
                        if let count = object["binary_bytes"]?.intValue, let preview = object["preview_base64"]?.stringValue {
                            return .binary(byteCount: count, preview: Array(Data(base64Encoded: preview) ?? Data()))
                        }
                    }
                    return .text(String(describing: cell))
                })
            }
            let store = try await WorkspaceQueryResultStore.makeTemporary(); try await store.append(rows)
            let page = WorkspaceQueryResultPage(columns: columns, store: store, rowCount: entry["affected_or_returned_rows"]?.intValue ?? rows.count)
            results.append(.init(statement: statement, state: .completed(page), elapsedSeconds: entry["elapsed_seconds"]?.doubleValue ?? 0))
        }
        return results
    }
}

private struct MCPNativeResultView: View {
    let results: [WorkspaceStatementResult]
    let database: String?
    let type: DatabaseType
    let truncated: Bool
    let dismiss: () -> Void
    @State private var selected = 0
    @State private var safetyLock = WorkspaceSafetyLock()
    @State private var pending = WorkspacePendingChangesRegistry()
    @State private var contentID = WorkspaceContentTabID.queryDocument(UUID())
    var body: some View {
        VStack(spacing: 0) {
            if truncated {
                Text(AppCopy.current.text("结果已按 MCP 限制截断", "Results were truncated by MCP limits"))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(8)
                Divider()
            }
            WorkspaceQueryResultView(state: results.first?.state ?? .idle, statementResults: results,
                selectedStatementResultIndex: $selected, elapsedSeconds: results.reduce(0) { $0 + $1.elapsedSeconds },
                currentDatabase: database, databaseType: type, supportsDataEditing: false, safetyLock: safetyLock,
                contentID: contentID, pendingChangesRegistry: pending,
                fetchDetails: { _ in throw MCPFailure("MCP result metadata is unavailable.") },
                applyChanges: { _ in throw MCPFailure("MCP result snapshots cannot be edited.") },
                dismiss: dismiss, updateInspectorContext: { _ in })
        }
    }
}
