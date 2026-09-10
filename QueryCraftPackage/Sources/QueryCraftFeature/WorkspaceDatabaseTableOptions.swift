import Foundation

public struct WorkspaceDatabaseTableOptions: Equatable, Sendable {
    public var engine = ""
    public var characterSet = ""
    public var collation = ""
    public var rowFormat = ""
    public var autoIncrement = ""
    public var comment = ""
    public var averageRowLength = ""
    public var minimumRows = ""
    public var maximumRows = ""
    public var keyBlockSize = ""

    public init(
        engine: String = "",
        characterSet: String = "",
        collation: String = "",
        rowFormat: String = "",
        autoIncrement: String = "",
        comment: String = "",
        averageRowLength: String = "",
        minimumRows: String = "",
        maximumRows: String = "",
        keyBlockSize: String = ""
    ) {
        self.engine = engine
        self.characterSet = characterSet
        self.collation = collation
        self.rowFormat = rowFormat
        self.autoIncrement = autoIncrement
        self.comment = comment
        self.averageRowLength = averageRowLength
        self.minimumRows = minimumRows
        self.maximumRows = maximumRows
        self.keyBlockSize = keyBlockSize
    }

    mutating func applyCharacterSet(
        _ value: String,
        choices: WorkspaceDatabaseSchemaChoices
    ) {
        characterSet = value
        guard !value.isEmpty else {
            collation = ""
            return
        }
        if !collation.isEmpty,
           choices.contains(collation, inCharacterSet: value)
        {
            return
        }
        collation = choices.defaultCollation(forCharacterSet: value) ?? ""
    }

    mutating func applyCollation(
        _ value: String,
        choices: WorkspaceDatabaseSchemaChoices
    ) {
        collation = value
        guard !value.isEmpty else { return }
        characterSet = choices.characterSet(forCollation: value)
            ?? characterSetFromCollation(value)
    }

    private func characterSetFromCollation(_ value: String) -> String {
        if value == "binary" { return "binary" }
        return value.split(separator: "_", maxSplits: 1)
            .first.map(String.init) ?? ""
    }
}
