import AppKit
import Foundation
@testable import QueryCraftFeature

private struct DemoEndpoint: Decodable {
    let host: String
    let port: Int
    let database: String
}
private struct DemoManifest: Decodable {
    let source: DemoEndpoint
    let target: DemoEndpoint
}
private struct Failure: Error, CustomStringConvertible { let description: String }

/// Installs only the two localhost demo profiles into Dev, never the stable store.
@main struct InstallSchemaComparisonDemo {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: env["QC_DEMO_DIRECTORY"]!)
        let manifest = try JSONDecoder().decode(DemoManifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        guard manifest.source.host == "127.0.0.1", manifest.target.host == "127.0.0.1",
              manifest.source.database == "qc_demo_source", manifest.target.database == "qc_demo_target" else { throw Failure(description: "Unexpected demo endpoints") }
        let driver = URL(fileURLWithPath: env["QC_DEMO_DRIVER"]!)
        guard let bundle = Bundle(url: driver) else { throw Failure(description: "MySQL driver missing") }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw Failure(description: "Driver API mismatch") }
        try await entry.init().activate()
        func configuration(_ endpoint: DemoEndpoint) -> DatabaseConnectionConfiguration {
            .init(databaseType: .mysql, host: endpoint.host, port: endpoint.port, authentication: .usernamePassword(username: "root", password: nil), database: endpoint.database, tlsMode: .disabled)
        }
        let options = SchemaComparisonOptions(enableRollback: true)
        let loader = SchemaComparisonCatalogLoader(sessionFactory: DefaultWorkspaceSessionFactory(), options: options)
        let source = try await loader.load(configuration: configuration(manifest.source)) { _ in }
        let target = try await loader.load(configuration: configuration(manifest.target)) { _ in }
        let result = try await SchemaComparisonNativeEngine().analyze(source: source, target: target, options: options)
        let changes = result.differences.filter { $0.status != .equal }
        guard changes.count == 21, result.plan.rollbackComplete else { throw Failure(description: "Expected the 21-change baseline. Use reset before installing profiles.") }
        let database = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/QueryCraftDev/QueryCraft.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { throw Failure(description: "Dev connection store does not exist") }
        let repository = SQLiteConnectionProfileRepository(databaseURL: database)
        let prior = try await repository.fetchAll()
        let sourceID = UUID(uuidString: "B58951A2-5BA5-42FC-9B32-5F66384998AA")!
        let targetID = UUID(uuidString: "2098F1F3-5D45-491B-8FA1-37E72940A8D8")!
        let profiles = [(sourceID, "00 本地演练·源（MySQL 5.7）", manifest.source), (targetID, "01 本地演练·目标（MySQL 8.0）", manifest.target)]
        for (id, name, endpoint) in profiles {
            let old = prior.first { $0.id == id }
            if let old, old.host != "127.0.0.1" || old.name != name { throw Failure(description: "Demo profile ID is already used by another connection") }
            let profile = ConnectionProfile(id: id, name: name, groupID: old?.groupID, host: endpoint.host, port: endpoint.port, username: "root", defaultDatabase: endpoint.database, tlsMode: .disabled, storesCredential: false, sortIndex: old?.sortIndex ?? 0, createdAt: old?.createdAt ?? .now)
            if old == nil { try await repository.insert(profile) }
            else if old != profile { throw Failure(description: "Existing demo profile differs; refusing to overwrite connection settings") }
        }
        let after = try await repository.fetchAll()
        for profile in prior where profile.id != sourceID && profile.id != targetID {
            guard after.first(where: { $0.id == profile.id }) == profile else { throw Failure(description: "An existing profile changed unexpectedly") }
        }
        let saved = SchemaComparisonConfiguration(source: .init(profileID: sourceID, database: manifest.source.database), target: .init(profileID: targetID, database: manifest.target.database), options: options)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: directory.appending(path: "结构对比演练.json"), options: .atomic)
        try result.plan.sql.write(to: directory.appending(path: "预期部署.sql"), atomically: true, encoding: .utf8)
        try result.plan.rollbackSQL.write(to: directory.appending(path: "预期回退.sql"), atomically: true, encoding: .utf8)
        try changes.map { $0.table + " · " + $0.displayName + " · " + $0.changeSummary }.joined(separator: "\n").write(to: directory.appending(path: "预期差异.txt"), atomically: true, encoding: .utf8)
        print("PASS localhost driver connections, 21 baseline changes, complete rollback, two Dev profiles installed; existing profiles unchanged")
    }
}
