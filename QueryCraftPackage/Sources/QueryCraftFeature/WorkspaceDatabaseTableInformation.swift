public struct WorkspaceDatabaseTableInformation: Equatable, Sendable {
    public let dataSize: Int64?
    public let indexSize: Int64?
    public let comment: String
    public let engine: String?
    public let collation: String?
    public let rowFormat: String?
    public let estimatedRowCount: Int64?
    public let nextAutoIncrement: Int64?
    public let averageRowLength: Int64?
    public let minimumRows: Int64?
    public let maximumRows: Int64?
    public let keyBlockSize: Int64?
    public let creationTime: String?
    public let updateTime: String?

    public init(
        dataSize: Int64?,
        indexSize: Int64?,
        comment: String,
        engine: String? = nil,
        collation: String? = nil,
        rowFormat: String? = nil,
        estimatedRowCount: Int64? = nil,
        nextAutoIncrement: Int64? = nil,
        averageRowLength: Int64? = nil,
        minimumRows: Int64? = nil,
        maximumRows: Int64? = nil,
        keyBlockSize: Int64? = nil,
        creationTime: String? = nil,
        updateTime: String? = nil
    ) {
        self.dataSize = dataSize
        self.indexSize = indexSize
        self.comment = comment
        self.engine = engine
        self.collation = collation
        self.rowFormat = rowFormat
        self.estimatedRowCount = estimatedRowCount
        self.nextAutoIncrement = nextAutoIncrement
        self.averageRowLength = averageRowLength
        self.minimumRows = minimumRows
        self.maximumRows = maximumRows
        self.keyBlockSize = keyBlockSize
        self.creationTime = creationTime
        self.updateTime = updateTime
    }

    public var totalSize: Int64? {
        guard let dataSize, let indexSize else { return nil }
        let (total, overflow) = dataSize.addingReportingOverflow(indexSize)
        return overflow ? nil : total
    }

    public var tableOptions: WorkspaceDatabaseTableOptions {
        WorkspaceDatabaseTableOptions(
            engine: engine ?? "",
            characterSet: Self.characterSet(from: collation),
            collation: collation ?? "",
            rowFormat: rowFormat?.uppercased() ?? "",
            autoIncrement: nextAutoIncrement.map(String.init) ?? "",
            comment: comment,
            averageRowLength: averageRowLength.map(String.init) ?? "",
            minimumRows: minimumRows.map(String.init) ?? "",
            maximumRows: maximumRows.map(String.init) ?? "",
            keyBlockSize: keyBlockSize.map(String.init) ?? ""
        )
    }

    public static func numericCreateOption(
        _ name: String,
        in createOptions: String
    ) -> Int64? {
        let prefix = name.lowercased() + "="
        for component in createOptions.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(component)
            guard value.lowercased().hasPrefix(prefix) else { continue }
            return Int64(value.dropFirst(prefix.count))
        }
        return nil
    }

    private static func characterSet(from collation: String?) -> String {
        guard let collation, !collation.isEmpty else { return "" }
        if collation == "binary" { return "binary" }
        return collation.split(separator: "_", maxSplits: 1)
            .first.map(String.init) ?? ""
    }
}
