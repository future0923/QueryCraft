import Foundation

enum QueryCraftUITestFixtures {
    static let profile = ConnectionProfile(
        id: UUID(uuidString: "8E1C5E38-8485-4D07-8EF0-4DBEDB0DD860")!,
        name: "Local MySQL",
        groupID: nil,
        host: "db.internal.test",
        port: 4407,
        username: "querycraft_editor",
        defaultDatabase: "saved_database",
        tlsMode: .disabled,
        storesCredential: false,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    static let alternateProfile = ConnectionProfile(
        id: UUID(uuidString: "2D99D3D3-B0B8-4B44-AAD6-37C087CD4F08")!,
        name: "Analytics MySQL",
        groupID: nil,
        host: "analytics.internal.test",
        port: 3307,
        username: "analytics_reader",
        defaultDatabase: "analytics",
        tlsMode: .disabled,
        storesCredential: false,
        sortIndex: 1,
        createdAt: Date(timeIntervalSince1970: 1)
    )

    static var usesSeededProfile: Bool {
        ProcessInfo.processInfo.environment["QUERYCRAFT_UI_TEST_SEEDED_PROFILE"] == "1"
    }

    static var usesMultipleProfiles: Bool {
        ProcessInfo.processInfo.environment[
            "QUERYCRAFT_UI_TEST_MULTIPLE_PROFILES"
        ] == "1"
    }

    static var profiles: [ConnectionProfile] {
        guard usesSeededProfile else { return [] }
        return usesMultipleProfiles ? [profile, alternateProfile] : [profile]
    }

    static let objectDetails: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetails
    ] = [
        WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        ): WorkspaceDatabaseObjectDetails(
            columns: [
                WorkspaceDatabaseColumn(
                    name: "id",
                    type: "bigint unsigned",
                    collation: nil,
                    isNullable: false,
                    key: "PRI",
                    defaultValue: nil,
                    extra: "auto_increment",
                    comment: ""
                ),
                WorkspaceDatabaseColumn(
                    name: "name",
                    type: "varchar(255)",
                    collation: "utf8mb4_0900_ai_ci",
                    isNullable: false,
                    key: "",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                ),
            ],
            ddl: "CREATE TABLE `users` (`id` bigint unsigned NOT NULL AUTO_INCREMENT, `name` varchar(255) NOT NULL, PRIMARY KEY (`id`))"
        ),
        WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "active_users",
            kind: .view
        ): WorkspaceDatabaseObjectDetails(
            columns: [
                WorkspaceDatabaseColumn(
                    name: "id",
                    type: "bigint unsigned",
                    collation: nil,
                    isNullable: false,
                    key: "",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                ),
            ],
            ddl: "CREATE VIEW `active_users` AS SELECT `id` FROM `users`"
        ),
    ]

    static let objectData: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataPage
    ] = [
        WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        ): WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("1"), .text("Alice")]
                ),
                WorkspaceDatabaseDataRow(
                    id: 1,
                    values: [.text("2"), .null]
                ),
            ],
            offset: 0,
            limit: WorkspaceDatabaseDataPage.defaultLimit,
            hasNextPage: false
        ),
        WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "active_users",
            kind: .view
        ): WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id")
            ],
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1")])
            ],
            offset: 0,
            limit: WorkspaceDatabaseDataPage.defaultLimit,
            hasNextPage: false
        ),
    ]

    static let objectIndexes: [
        WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseIndex]
    ] = [
        WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        ): [
            WorkspaceDatabaseIndex(
                name: "PRIMARY",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "id",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    )
                ],
                isUnique: true,
                type: "BTREE",
                cardinality: 2,
                isVisible: true,
                comment: ""
            ),
            WorkspaceDatabaseIndex(
                name: "idx_users_name",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "name",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    )
                ],
                isUnique: false,
                type: "BTREE",
                cardinality: 2,
                isVisible: true,
                comment: ""
            ),
        ]
    ]
}
