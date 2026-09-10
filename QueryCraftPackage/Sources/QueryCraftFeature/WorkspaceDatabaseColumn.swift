public struct WorkspaceDatabaseColumn: Equatable, Identifiable, Sendable {
    public let name: String
    public let type: String
    public let collation: String?
    public let isNullable: Bool
    public let key: String
    public let defaultValue: String?
    public let extra: String
    public let comment: String
    public let generationExpression: String

    public init(
        name: String,
        type: String,
        collation: String?,
        isNullable: Bool,
        key: String,
        defaultValue: String?,
        extra: String,
        comment: String,
        generationExpression: String = ""
    ) {
        self.name = name
        self.type = type
        self.collation = collation
        self.isNullable = isNullable
        self.key = key
        self.defaultValue = defaultValue
        self.extra = extra
        self.comment = comment
        self.generationExpression = generationExpression
    }

    public var id: String { name }

    public var isGenerated: Bool {
        let normalizedExtra = extra.uppercased()
        return normalizedExtra.contains("VIRTUAL GENERATED")
            || normalizedExtra.contains("STORED GENERATED")
    }
}
