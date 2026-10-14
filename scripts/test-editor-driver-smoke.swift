import AppKit
import Foundation
import SwiftUI
@testable import QueryCraftFeature

private struct SmokeFailure: Error {}

@main
struct EditorDriverSmoke {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch {
            print("FAIL harness error type: \(String(reflecting: type(of: error)))")
            print("FAIL harness detail: \(error)")
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let type = DatabaseType(rawValue: env["CHECK_DRIVER"] ?? ""),
              let bundle = Bundle(path: env["CHECK_BUNDLE"] ?? "") else { throw SmokeFailure() }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw SmokeFailure() }
        try await entry.init().activate()
        let authentication: DatabaseConnectionAuthentication = type == .mysql || type == .postgresql || type == .doris || type == .redis
            ? .usernamePassword(username: env["CHECK_USER"]!, password: env["CHECK_PASSWORD"]) : .none
        let config = DatabaseConnectionConfiguration(databaseType: type, host: "127.0.0.1",
            port: Int(env["CHECK_PORT"]!)!, authentication: authentication,
            database: env["CHECK_DATABASE"].flatMap { $0.isEmpty ? nil : $0 }, tlsMode: .disabled)
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: config)
        do {
            try await session.connect()
            let databases = try await session.fetchDatabases()
            guard !databases.isEmpty else { throw SmokeFailure() }
            print("PASS \(type.rawValue): installed driver loaded, connected, database metadata read")
            switch type {
            case .mysql, .postgresql, .doris:
                let sql = "SELECT '中文😀' AS editor_probe, 42 AS count;"
                let result = try await session.executeReadOnlyQuery(sql, database: nil, onBatch: { _ in })
                guard result.columns.count == 2 else { throw SmokeFailure() }
                try await renderSQL(sql, type: type, label: "query")
                let system = Set(["information_schema", "mysql", "sys", "performance_schema", "template0", "template1"])
                var ddlRendered = false
                for database in databases.filter({ !system.contains($0.lowercased()) }).prefix(8) {
                    let objects = try await session.fetchObjects(in: database)
                    guard let table = objects.first(where: { $0.kind == .table }) else { continue }
                    let details = try await session.fetchDetails(for: table, in: database)
                    guard !details.ddl.isEmpty else { throw SmokeFailure() }
                    try await renderSQL(details.ddl, type: type, label: "ddl")
                    ddlRendered = true
                    break
                }
                guard ddlRendered else { throw SmokeFailure() }
                print("PASS \(type.rawValue): read-only SELECT, live DDL, light/dark SQL views")
            case .elasticsearch:
                guard let requests = session as? any WorkspaceRequestExecutingSession else { throw SmokeFailure() }
                let response = try await requests.executeRequest(.init(method: .get, path: "/_cluster/health"))
                guard response.statusCode == 200 else { throw SmokeFailure() }
                try await renderJSON(String(decoding: response.body, as: UTF8.self), type: type)
                print("PASS elasticsearch: read-only cluster response, light/dark JSON views")
            case .redis:
                guard let redis = session as? any RedisWorkspaceSession else { throw SmokeFailure() }
                let json = #"{"editor":"中文😀","enabled":true,"count":42}"#
                let response = try await redis.executeRedisCommand(.init(source: "ECHO", arguments: ["ECHO", json]), databaseIndex: 0)
                guard response.reply == .bulkString(json) || response.reply == .simpleString(json) else { throw SmokeFailure() }
                try await renderJSON(json, type: type)
                print("PASS redis: read-only ECHO round trip, light/dark JSON views")
            case .kafka:
                guard let metadata = session as? any WorkspaceKafkaTopicDetailsProviding else { throw SmokeFailure() }
                let objects = try await session.fetchObjects(in: "Kafka")
                guard let topic = objects.first(where: { !$0.name.hasPrefix("__") }) else { throw SmokeFailure() }
                let details = try await metadata.fetchTopicDetails(topic: topic.name)
                guard !details.partitions.isEmpty else { throw SmokeFailure() }
                let data = try JSONSerialization.data(withJSONObject: ["partitions": details.partitions.map { ["id": Int($0.id), "replicas": $0.replicas.map(Int.init)] }], options: [.prettyPrinted])
                try await renderJSON(String(decoding: data, as: UTF8.self), type: type)
                print("PASS kafka: read-only topic metadata, light/dark shared JSON views (no message consumption)")
            }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }

    @MainActor static func renderSQL(_ source: String, type: DatabaseType, label: String) async throws {
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(in: .init(location: 0, length: source.utf16.count), revision: .init(1), context: .init(databaseType: type))
        guard !highlights.isEmpty else { throw SmokeFailure() }
        for mode in EditorColorMode.allCases {
            let view = WorkspaceDatabaseDDLView(ddl: source, highlightContext: .init(databaseType: type))
                .environment(\.colorScheme, mode == .dark ? .dark : .light)
            try await render(view, name: "\(type.rawValue)-\(label)-\(mode.rawValue)", mode: mode)
        }
    }

    @MainActor static func renderJSON(_ source: String, type: DatabaseType) async throws {
        _ = try JSONSerialization.jsonObject(with: Data(source.utf8))
        for mode in EditorColorMode.allCases {
            let view = WorkspaceJSONTextView(text: .constant(source), accessibilityLabel: "Driver smoke JSON")
                .environment(\.colorScheme, mode == .dark ? .dark : .light)
            try await render(view, name: "\(type.rawValue)-json-\(mode.rawValue)", mode: mode)
        }
    }

    @MainActor static func render<V: View>(_ content: V, name: String, mode: EditorColorMode) async throws {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: mode.appearanceName)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SmokeFailure() }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let context = CGContext(data: nil, width: 1400, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SmokeFailure() }
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: host.bounds.height)
        context.scaleBy(x: 1, y: -1)
        window.appearance?.performAsCurrentDrawingAppearance { host.layer?.render(in: context) }
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw SmokeFailure() }
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHECK_OUTPUT"]!).appendingPathComponent(name + ".png"))
    }
}
