import Foundation
import QueryCraftFeature
#if !PACKAGED_DRIVER
import QueryCraftMariaDBTransportV4
#endif

@main
struct SQLWaitingCheck {
    static func main() async throws {
#if PACKAGED_DRIVER
        guard let bundle = Bundle(path: CommandLine.arguments[2]) else { fatalError("Missing driver bundle") }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { fatalError("Invalid driver entry") }
        try await entry.init().activate()
        let type: DatabaseType = bundle.bundleURL.lastPathComponent.hasPrefix("Doris") ? .doris : .mysql
        let client = try await DatabaseDriverRegistry.shared.makeSession(configuration: .init(databaseType: type,
            host: "127.0.0.1", port: Int(CommandLine.arguments[1])!, username: "fixture", password: nil,
            database: nil, tlsMode: .disabled))
        try await client.connect()
        let query: @Sendable (String) async throws -> Void = { sql in
            _ = try await client.executeStatement(sql, kind: .read, database: nil, onBatch: { _ in })
        }
        let stream = query
        print("PASS installed \(type.rawValue) driver loaded: \(bundle.bundleURL.path)")
#else
        let client = MariaDBClient(configuration: .init(host: "127.0.0.1",
            port: Int(CommandLine.arguments[1])!, username: "fixture",
            password: nil, database: nil, tlsMode: .disabled))
        try await client.connect()
        let query: @Sendable (String) async throws -> Void = { sql in _ = try await client.query(sql) }
        let stream: @Sendable (String) async throws -> Void = { sql in
            _ = try await client.queryStream(sql, onBatch: { _ in })
        }
#endif
        var start = ContinuousClock.now
        try await query("SELECT SLEEP(12)")
        precondition(start.duration(to: .now) > .seconds(10))
        print("PASS query waits beyond 10 seconds")
        start = .now
        try await stream("SELECT SLEEP(12) /* stream */")
        precondition(start.duration(to: .now) > .seconds(10))
        print("PASS streamed query waits beyond 10 seconds")
        let pending = Task { try await query("SELECT SLEEP(60)") }
        try await Task.sleep(for: .milliseconds(200))
        pending.cancel()
        do {
            _ = try await pending.value
            preconditionFailure("Cancelled query unexpectedly completed")
        } catch is CancellationError {
            print("PASS manual cancellation still interrupts waiting")
        }
        try await query("SELECT 1")
        print("PASS connection remains usable after cancellation")
        await client.close()
    }
}
