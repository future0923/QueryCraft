public enum WorkspaceDatabaseSchemaChoiceCatalog {
    typealias Option = WorkspaceDatabaseSchemaOptionPicker.Option

    public static let columnTypeValues = columnTypes.map(\.value)

    static let columnTypes = options([
        "BIT",
        "BIT(1)",
        "BIGINT",
        "BIGINT UNSIGNED",
        "INTEGER",
        "INTEGER UNSIGNED",
        "INT",
        "INT UNSIGNED",
        "MEDIUMINT",
        "MEDIUMINT UNSIGNED",
        "SMALLINT",
        "SMALLINT UNSIGNED",
        "TINYINT",
        "TINYINT UNSIGNED",
        "TINYINT(1)",
        "DECIMAL",
        "DECIMAL(10,2)",
        "DECIMAL(10,2) UNSIGNED",
        "NUMERIC(10,2)",
        "FIXED(10,2)",
        "FLOAT",
        "FLOAT UNSIGNED",
        "DOUBLE",
        "DOUBLE UNSIGNED",
        "DOUBLE PRECISION",
        "REAL",
        "BOOL",
        "BOOLEAN",
        "CHAR(1)",
        "CHAR(255)",
        "NCHAR(255)",
        "VARCHAR(255)",
        "NVARCHAR(255)",
        "TINYTEXT",
        "TEXT",
        "MEDIUMTEXT",
        "LONGTEXT",
        "BINARY(255)",
        "VARBINARY(255)",
        "TINYBLOB",
        "BLOB",
        "MEDIUMBLOB",
        "LONGBLOB",
        "DATE",
        "TIME",
        "TIME(6)",
        "DATETIME",
        "DATETIME(6)",
        "TIMESTAMP",
        "TIMESTAMP(6)",
        "YEAR",
        "JSON",
        "ENUM('value')",
        "SET('value')",
        "GEOMETRY",
        "POINT",
        "LINESTRING",
        "POLYGON",
        "MULTIPOINT",
        "MULTILINESTRING",
        "MULTIPOLYGON",
        "GEOMETRYCOLLECTION",
    ])

    static func characterSets(
        _ schemaChoices: WorkspaceDatabaseSchemaChoices
    ) -> [Option] {
        databaseDefaultOption + options(
            schemaChoices.characterSets.isEmpty
                ? fallbackCharacterSets
                : schemaChoices.characterSets
        )
    }

    static func collations(
        _ schemaChoices: WorkspaceDatabaseSchemaChoices,
        characterSet: String
    ) -> [Option] {
        let available = schemaChoices.collations
            .filter { characterSet.isEmpty || $0.characterSet == characterSet }
            .map(\.name)
        return databaseDefaultOption + options(
            available.isEmpty ? fallbackCollations : available
        )
    }

    static var defaultPresets: [Option] {
        [
            Option(
                value: WorkspaceDatabaseSchemaEditorState.DefaultPreset.none
                    .rawValue,
                title: "EMPTY"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.DefaultPreset.null
                    .rawValue,
                title: "NULL"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.DefaultPreset
                    .currentTimestamp.rawValue,
                title: "CURRENT_TIMESTAMP"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.DefaultPreset.now
                    .rawValue,
                title: "NOW()"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.DefaultPreset.custom
                    .rawValue,
                title: "Custom Value..."
            ),
        ]
    }

    static func defaultPresets(allowsNull: Bool) -> [Option] {
        guard !allowsNull else { return defaultPresets }
        return defaultPresets.filter {
            $0.value != WorkspaceDatabaseSchemaEditorState.DefaultPreset.null
                .rawValue
        }
    }

    static var extraPresets: [Option] {
        [
            Option(
                value: WorkspaceDatabaseSchemaEditorState.ExtraPreset.none
                    .rawValue,
                title: "NONE"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.ExtraPreset
                    .autoIncrement.rawValue,
                title: "AUTO_INCREMENT"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.ExtraPreset
                    .onUpdateCurrentTimestamp.rawValue,
                title: "ON UPDATE CURRENT_TIMESTAMP"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.ExtraPreset.invisible
                    .rawValue,
                title: "INVISIBLE"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.ExtraPreset.custom
                    .rawValue,
                title: "Manual Input..."
            ),
        ]
    }

    private static var databaseDefaultOption: [Option] {
        [
            Option(
                value: "",
                title: "default"
            ),
        ]
    }

    private static let fallbackCharacterSets = [
        "armscii8", "ascii", "big5", "binary", "cp1250", "cp1251",
        "cp1256", "cp1257", "cp850", "cp852", "cp866", "cp932",
        "dec8", "eucjpms", "euckr", "gb18030", "gb2312", "gbk",
        "geostd8", "greek", "hebrew", "hp8", "keybcs2", "koi8r",
        "koi8u", "latin1", "latin2", "latin5", "latin7", "macce",
        "macroman", "sjis", "swe7", "tis620", "ucs2", "ujis",
        "utf16", "utf16le", "utf32", "utf8mb3", "utf8mb4",
    ]

    private static let fallbackCollations = [
            "utf8mb4_0900_ai_ci",
            "utf8mb4_0900_as_ci",
            "utf8mb4_0900_as_cs",
            "utf8mb4_unicode_ci",
            "utf8mb4_general_ci",
            "utf8mb4_bin",
            "utf8_unicode_ci",
            "utf8_general_ci",
            "utf8_bin",
            "ascii_general_ci",
            "ascii_bin",
            "binary",
    ]

    static var indexKinds: [Option] {
        [
            Option(
                value: WorkspaceDatabaseSchemaEditorState.IndexKind.primary.rawValue,
                title: "PRIMARY"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.IndexKind.unique.rawValue,
                title: "UNIQUE"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.IndexKind.normal.rawValue,
                title: "INDEX"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.IndexKind.fulltext.rawValue,
                title: "FULLTEXT"
            ),
            Option(
                value: WorkspaceDatabaseSchemaEditorState.IndexKind.spatial.rawValue,
                title: "SPATIAL"
            ),
        ]
    }

    static let indexMethods = options(["BTREE", "HASH"])

    static var onUpdateExpressions: [Option] {
        [
            Option(value: "", title: "NONE"),
            Option(value: "CURRENT_TIMESTAMP", title: "CURRENT_TIMESTAMP"),
        ]
    }

    static var generatedStorages: [Option] {
        WorkspaceDatabaseSchemaEditorState.GeneratedStorage.allCases.map {
            Option(value: $0.rawValue, title: $0.rawValue)
        }
    }

    static func columnNames(_ names: [String]) -> [Option] {
        options(names)
    }

    private static func options(_ values: [String]) -> [Option] {
        values.map { Option(value: $0, title: $0) }
    }
}
