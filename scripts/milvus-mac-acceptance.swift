import AppKit
import Foundation
@testable import QueryCraftFeature

private actor BatchSink {
    var batch: WorkspaceDatabaseDataBatch?
    func receive(_ value: WorkspaceDatabaseDataBatch) { batch = value }
}

@main
struct MilvusMacAcceptance {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("CHECK_FAILED \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard !secret.isEmpty else { fatalError("Password is required on stdin") }
        let installer = DatabaseDriverPackageInstaller(maintainsInstalledDrivers: false)
        for driver in await installer.loadInstalledDrivers() { await DatabaseDriverRegistry.shared.register(driver) }
        guard await DatabaseDriverRegistry.shared.isInstalled(.milvus) else { print("CHECK_FAILED Installed Milvus driver did not load"); exit(1) }
        print("PASS installed Dev driver loaded")
        let repository = SQLiteConnectionProfileRepository()
        let profiles = try await repository.fetchAll()
        let existing = profiles.first { $0.databaseType == .milvus && $0.host == "c-72f701468a58f00e.milvus.aliyuncs.com" }
        let profile = ConnectionProfile(id: existing?.id ?? UUID(), name: existing?.name ?? "阿里云 Milvus",
            groupID: existing?.groupID, databaseType: .milvus, host: "c-72f701468a58f00e.milvus.aliyuncs.com",
            port: 19530, username: "root", defaultDatabase: "default", tlsMode: .disabled, storesCredential: true,
            sortIndex: existing?.sortIndex ?? profiles.count, createdAt: existing?.createdAt ?? .now)
        let credentials = SharedKeychainCredentialStore(allowsInteraction: false)
        try await credentials.save(password: secret, for: profile.id)
        guard try await credentials.password(for: profile.id) == secret else { fatalError("Credential verification failed") }
        if existing == nil { try await repository.insert(profile) } else { try await repository.update(profile) }
        print("PASS saved Dev profile \(profile.id.uuidString); secret verified in shared Keychain vault")
        let config = DatabaseConnectionConfiguration(databaseType: .milvus, host: profile.host, port: profile.port,
            username: profile.username, password: secret, database: "default", tlsMode: .disabled)
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: config)
        do {
            try await session.connect()
            let objects = try await session.fetchObjects(in: "default")
            print("PASS collections \(objects.map(\.name).joined(separator: ", "))")
            for object in objects {
                let schema = try await session.fetchDetails(for: object, in: "default")
                print("PASS schema \(object.name) fields \(schema.columns.count)")
                for offset in [0, 25, 0] {
                    let sink = BatchSink()
                    _ = try await session.fetchDataPage(for: object, in: "default", offset: offset, limit: 25, sort: .none) { await sink.receive($0) }
                    let batch = await sink.batch
                    print("PASS page \(object.name) offset \(offset), rows \(batch?.rows.count ?? 0), columns \(batch?.columns.count ?? 0)")
                }
            }
            await session.close()
        } catch {
            await session.close()
            print("LIVE_CHECK_FAILED \(error.localizedDescription)")
            exit(2)
        }
    }
}
