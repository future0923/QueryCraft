import Testing

@testable import QueryCraftFeature

struct WorkspaceDatabaseTableInformationTests {
    @Test
    func preservesStorageMetadataAndComputesTotalSize() {
        let information = WorkspaceDatabaseTableInformation(
            dataSize: 12_000,
            indexSize: 3_000,
            comment: "users",
            engine: "InnoDB",
            collation: "utf8mb4_0900_ai_ci",
            rowFormat: "Dynamic",
            estimatedRowCount: 42,
            nextAutoIncrement: 43,
            averageRowLength: 128,
            minimumRows: 10,
            maximumRows: 100_000,
            keyBlockSize: 8,
            creationTime: "2026-08-12 09:00:00",
            updateTime: "2026-08-12 09:30:00"
        )

        #expect(information.engine == "InnoDB")
        #expect(information.collation == "utf8mb4_0900_ai_ci")
        #expect(information.rowFormat == "Dynamic")
        #expect(information.estimatedRowCount == 42)
        #expect(information.nextAutoIncrement == 43)
        #expect(
            information.tableOptions
                == WorkspaceDatabaseTableOptions(
                    engine: "InnoDB",
                    characterSet: "utf8mb4",
                    collation: "utf8mb4_0900_ai_ci",
                    rowFormat: "DYNAMIC",
                    autoIncrement: "43",
                    comment: "users",
                    averageRowLength: "128",
                    minimumRows: "10",
                    maximumRows: "100000",
                    keyBlockSize: "8"
                )
        )
        #expect(information.creationTime == "2026-08-12 09:00:00")
        #expect(information.updateTime == "2026-08-12 09:30:00")
        #expect(information.totalSize == 15_000)
    }

    @Test
    func extractsNumericValuesFromCreateOptions() {
        let createOptions = "stats_persistent=default min_rows=10 "
            + "max_rows=100000 avg_row_length=128 key_block_size=8"

        #expect(
            WorkspaceDatabaseTableInformation.numericCreateOption(
                "min_rows",
                in: createOptions
            ) == 10
        )
        #expect(
            WorkspaceDatabaseTableInformation.numericCreateOption(
                "max_rows",
                in: createOptions
            ) == 100_000
        )
        #expect(
            WorkspaceDatabaseTableInformation.numericCreateOption(
                "avg_row_length",
                in: createOptions
            ) == 128
        )
        #expect(
            WorkspaceDatabaseTableInformation.numericCreateOption(
                "key_block_size",
                in: createOptions
            ) == 8
        )
    }
}
