import Foundation
import GRDB

actor SQLiteApplicationDatabase {
    static let shared = SQLiteApplicationDatabase(
        databaseURL: defaultDatabaseURL
    )

    private let databaseURL: URL?
    private var cachedDatabaseQueue: DatabaseQueue?

    init(databaseURL: URL?) {
        self.databaseURL = databaseURL
    }

    func read<Value: Sendable>(
        _ value: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        let databaseQueue = try makeDatabaseQueue()
        return try await databaseQueue.read(value)
    }

    func write<Value: Sendable>(
        _ updates: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        let databaseQueue = try makeDatabaseQueue()
        return try await databaseQueue.write(updates)
    }

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        if let cachedDatabaseQueue {
            return cachedDatabaseQueue
        }

        let databaseQueue: DatabaseQueue
        if let databaseURL {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            databaseQueue = try DatabaseQueue(path: databaseURL.path)
        } else {
            databaseQueue = try DatabaseQueue()
        }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("createConnectionProfile") { database in
            try database.create(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.primaryKey("id", .text).notNull()
                table.column("name", .text).notNull()
                table.column("groupName", .text)
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("username", .text).notNull()
                table.column("defaultDatabase", .text)
                table.column("storesCredential", .boolean).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("addConnectionTLSMode") { database in
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(
                    column: "tlsMode",
                    .text
                )
                .notNull()
                .defaults(to: ConnectionTLSMode.verifyIdentity.rawValue)
            }
        }
        migrator.registerMigration(
            "addSavedQueriesAndRecoverableDrafts"
        ) { database in
            try Self.createSavedQueryTable(in: database)
            try Self.createRecoverableDraftTable(in: database)
        }
        migrator.registerMigration("addWorkspaceRestoration") { database in
            try Self.createWorkspaceRestorationTable(in: database)
        }
        migrator.registerMigration(
            "addWorkspaceContentTabRestoration"
        ) { database in
            try database.alter(table: "workspaceRestoration") { table in
                table.add(column: "contentTabOrder", .blob)
                table.add(column: "selectedContentTab", .blob)
            }
        }
        migrator.registerMigration(
            "addConnectionGroupsAndProfileOrdering"
        ) { database in
            try Self.createConnectionGroupTable(in: database)
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(column: "groupID", .text)
                    .references(
                        ConnectionGroup.databaseTableName,
                        onDelete: .cascade
                    )
                table.add(column: "sortIndex", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            try Self.migrateLegacyConnectionGroups(in: database)
        }
        migrator.registerMigration(
            "addDatabaseContextRestoration"
        ) { database in
            try database.alter(table: "workspaceRestoration") { table in
                table.add(column: "databaseContexts", .blob)
                table.add(column: "selectedDatabaseContextID", .text)
            }
        }
        migrator.registerMigration(
            "replaceWorkspaceRestorationWithDatabaseContexts"
        ) { database in
            // QueryCraft has not shipped restoration compatibility yet. Reset
            // open-window state instead of carrying the legacy flat arrays.
            try database.drop(table: "workspaceRestoration")
            try Self.createDatabaseContextRestorationTable(in: database)
        }
        migrator.registerMigration("addConnectionDatabaseType") { database in
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(column: "databaseType", .text)
                    .notNull()
                    .defaults(to: DatabaseType.mysql.rawValue)
            }
        }
        migrator.registerMigration("addConnectionDatabaseProduct") { database in
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(column: "databaseProduct", .text)
                    .notNull()
                    .defaults(to: DatabaseProduct.mysql.rawValue)
            }
            try database.execute(
                sql: """
                    UPDATE connectionProfile
                    SET databaseProduct = ?
                    WHERE databaseType = ?
                    """,
                arguments: [
                    DatabaseProduct.postgresql.rawValue,
                    DatabaseType.postgresql.rawValue,
                ]
            )
        }
        migrator.registerMigration("addConnectionAuthenticationMethod") { database in
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(column: "authenticationMethod", .text)
                    .notNull()
                    .defaults(
                        to: DatabaseConnectionAuthenticationMethod
                            .usernamePassword.rawValue
                    )
            }
        }
        try migrator.migrate(databaseQueue)

        cachedDatabaseQueue = databaseQueue
        return databaseQueue
    }

    private static func createConnectionGroupTable(
        in database: Database
    ) throws {
        try database.create(
            table: ConnectionGroup.databaseTableName
        ) { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text)
                .notNull()
                .collate(.nocase)
                .unique()
            table.column("sortIndex", .integer).notNull()
            table.column("createdAt", .datetime).notNull()
        }
    }

    private static func migrateLegacyConnectionGroups(
        in database: Database
    ) throws {
        let names = try String.fetchAll(
            database,
            sql: """
                SELECT TRIM(groupName)
                FROM connectionProfile
                WHERE groupName IS NOT NULL AND TRIM(groupName) <> ''
                GROUP BY TRIM(groupName) COLLATE NOCASE
                ORDER BY TRIM(groupName) COLLATE NOCASE
                """
        )
        var groupIDsByName: [String: ConnectionGroup.ID] = [:]
        for (sortIndex, name) in names.enumerated() {
            let group = ConnectionGroup(
                id: UUID(),
                name: name,
                sortIndex: sortIndex,
                createdAt: .now
            )
            try group.insert(database)
            groupIDsByName[name] = group.id
        }

        for (name, groupID) in groupIDsByName {
            try database.execute(
                sql: """
                    UPDATE connectionProfile
                    SET groupID = ?
                    WHERE TRIM(groupName) = ? COLLATE NOCASE
                    """,
                arguments: [groupID, name]
            )
        }

        let profileIDs = try UUID.fetchAll(
            database,
            sql: """
                SELECT id
                FROM connectionProfile
                ORDER BY groupID, name COLLATE NOCASE, createdAt, id
                """
        )
        var nextIndexByGroup: [UUID?: Int] = [:]
        for profileID in profileIDs {
            let groupID = try UUID.fetchOne(
                database,
                sql: "SELECT groupID FROM connectionProfile WHERE id = ?",
                arguments: [profileID]
            )
            let sortIndex = nextIndexByGroup[groupID, default: 0]
            try database.execute(
                sql: """
                    UPDATE connectionProfile
                    SET sortIndex = ?
                    WHERE id = ?
                    """,
                arguments: [sortIndex, profileID]
            )
            nextIndexByGroup[groupID] = sortIndex + 1
        }
    }

    private static func createSavedQueryTable(in database: Database) throws {
        try database.create(table: SavedQuery.databaseTableName) { table in
            table.primaryKey("id", .text).notNull()
            table.column("connectionProfileID", .text)
                .notNull()
                .references(
                    ConnectionProfile.databaseTableName,
                    onDelete: .cascade
                )
            table.column("defaultDatabase", .text)
            table.column("name", .text).notNull()
            table.column("sql", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try database.create(
            index: "savedQueryByConnectionProfile",
            on: SavedQuery.databaseTableName,
            columns: ["connectionProfileID"]
        )
        try database.create(
            index: "savedQueryUniqueGeneralName",
            on: SavedQuery.databaseTableName,
            columns: ["connectionProfileID", "name"],
            options: .unique,
            condition: Column("defaultDatabase") == nil
        )
        try database.create(
            index: "savedQueryUniqueDatabaseName",
            on: SavedQuery.databaseTableName,
            columns: ["connectionProfileID", "defaultDatabase", "name"],
            options: .unique,
            condition: Column("defaultDatabase") != nil
        )
    }

    private static func createRecoverableDraftTable(
        in database: Database
    ) throws {
        try database.create(
            table: RecoverableDraft.databaseTableName
        ) { table in
            table.primaryKey("id", .text).notNull()
            table.column("workspaceID", .text).notNull()
            table.column("connectionProfileID", .text)
                .notNull()
                .references(
                    ConnectionProfile.databaseTableName,
                    onDelete: .cascade
                )
            table.column("defaultDatabase", .text)
            table.column("sql", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try database.create(
            index: "recoverableDraftByWorkspace",
            on: RecoverableDraft.databaseTableName,
            columns: ["workspaceID", "createdAt"]
        )
        try database.create(
            index: "recoverableDraftByConnectionProfile",
            on: RecoverableDraft.databaseTableName,
            columns: ["connectionProfileID"]
        )
    }

    private static func createWorkspaceRestorationTable(
        in database: Database
    ) throws {
        try database.create(
            table: "workspaceRestoration"
        ) { table in
            table.primaryKey("id", .text).notNull()
            table.column("connectionProfileID", .text)
                .notNull()
                .references(
                    ConnectionProfile.databaseTableName,
                    onDelete: .cascade
                )
            table.column("selectedDatabaseName", .text)
            table.column("selectedObjectName", .text)
            table.column("selectedObjectKind", .text)
            table.column("queryDocuments", .blob).notNull()
            table.column("selectedQueryDocumentID", .text)
            table.column("windowX", .double)
            table.column("windowY", .double)
            table.column("windowWidth", .double)
            table.column("windowHeight", .double)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try database.create(
            index: "workspaceRestorationByProfile",
            on: "workspaceRestoration",
            columns: ["connectionProfileID"]
        )
    }

    private static func createDatabaseContextRestorationTable(
        in database: Database
    ) throws {
        try database.create(table: "workspaceRestoration") { table in
            table.primaryKey("id", .text).notNull()
            table.column("connectionProfileID", .text)
                .notNull()
                .references(
                    ConnectionProfile.databaseTableName,
                    onDelete: .cascade
                )
            table.column("databaseContexts", .blob).notNull()
            table.column("selectedDatabaseContextID", .text).notNull()
            table.column("windowX", .double)
            table.column("windowY", .double)
            table.column("windowWidth", .double)
            table.column("windowHeight", .double)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try database.create(
            index: "workspaceRestorationByProfile",
            on: "workspaceRestoration",
            columns: ["connectionProfileID"]
        )
    }

    private static var defaultDatabaseURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "QueryCraft", directoryHint: .isDirectory)
            .appending(path: "QueryCraft.sqlite")
    }
}
