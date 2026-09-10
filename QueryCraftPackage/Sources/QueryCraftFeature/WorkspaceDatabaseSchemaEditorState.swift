import Foundation

public struct WorkspaceDatabaseSchemaEditorState: Equatable, Sendable {
    public enum DefaultMode: String, CaseIterable, Identifiable, Sendable {
        case none
        case null
        case value
        case expression

        public var id: Self { self }
    }

    public enum DefaultPreset: String, Sendable {
        case none
        case null
        case currentTimestamp
        case now
        case custom
    }

    public enum ExtraPreset: String, Sendable {
        case none
        case autoIncrement
        case onUpdateCurrentTimestamp
        case invisible
        case custom
    }

    public enum GeneratedStorage: String, CaseIterable, Identifiable, Sendable {
        case none
        case virtual
        case stored

        public var id: Self { self }
    }

    public struct ColumnDefinition: Equatable, Sendable {
        public var name: String
        public var type: String
        public var characterSet: String
        public var collation: String
        public var isNullable: Bool
        public var defaultMode: DefaultMode
        public var defaultValue: String
        public var onUpdateExpression: String
        public var isAutoIncrement: Bool
        public var isVisible: Bool
        public var generatedStorage: GeneratedStorage
        public var generationExpression: String
        public var comment: String

        public init(column: WorkspaceDatabaseColumn) {
            name = column.name
            type = column.type
            characterSet = Self.characterSet(from: column.collation)
            collation = column.collation ?? ""
            isNullable = column.isNullable
            if let defaultValue = column.defaultValue {
                defaultMode = Self.looksLikeExpression(defaultValue)
                    ? .expression
                    : .value
                self.defaultValue = defaultValue
            } else if column.isNullable {
                defaultMode = .null
                defaultValue = ""
            } else {
                defaultMode = .none
                defaultValue = ""
            }
            onUpdateExpression = Self.onUpdateExpression(from: column.extra)
            isAutoIncrement = column.extra.localizedCaseInsensitiveContains(
                "auto_increment"
            ) || column.extra.localizedCaseInsensitiveContains("identity")
            isVisible = !column.extra.localizedCaseInsensitiveContains("invisible")
            if column.extra.localizedCaseInsensitiveContains("stored generated") {
                generatedStorage = .stored
            } else if column.extra.localizedCaseInsensitiveContains(
                "virtual generated"
            ) {
                generatedStorage = .virtual
            } else {
                generatedStorage = .none
            }
            generationExpression = column.generationExpression
            comment = column.comment
        }

        private static func looksLikeExpression(_ value: String) -> Bool {
            let uppercased = value.uppercased()
            return uppercased == "CURRENT_TIMESTAMP"
                || uppercased.hasPrefix("CURRENT_TIMESTAMP(")
                || (value.hasPrefix("(") && value.hasSuffix(")"))
        }

        private static func onUpdateExpression(from extra: String) -> String {
            guard let clauseRange = extra.range(
                of: #"on\s+update\s+CURRENT_TIMESTAMP(?:\(\d+\))?"#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                return ""
            }
            let clause = extra[clauseRange]
            guard let expressionRange = clause.range(
                of: #"CURRENT_TIMESTAMP(?:\(\d+\))?"#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                return ""
            }
            return String(clause[expressionRange])
        }

        private static func characterSet(from collation: String?) -> String {
            guard let collation, !collation.isEmpty else { return "" }
            if collation == "binary" { return "binary" }
            return collation.split(separator: "_", maxSplits: 1)
                .first.map(String.init) ?? ""
        }

        public init(name: String = "", type: String = "VARCHAR(255)") {
            self.name = name
            self.type = type
            characterSet = ""
            collation = ""
            isNullable = true
            defaultMode = .null
            defaultValue = ""
            onUpdateExpression = ""
            isAutoIncrement = false
            isVisible = true
            generatedStorage = .none
            generationExpression = ""
            comment = ""
        }

        public var isGenerated: Bool { generatedStorage != .none }

        public var supportsCharacterSetAndCollation: Bool {
            let normalizedType = type.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).uppercased()
            let baseType = String(
                normalizedType.prefix { character in
                    character.isLetter
                }
            )
            return [
                "CHAR",
                "CHARACTER",
                "VARCHAR",
                "NCHAR",
                "NVARCHAR",
                "TINYTEXT",
                "TEXT",
                "MEDIUMTEXT",
                "LONGTEXT",
                "ENUM",
                "SET",
            ].contains(baseType)
        }

        public var extraDisplayValue: String {
            var values: [String] = []
            if isAutoIncrement { values.append("auto_increment") }
            if !onUpdateExpression.isEmpty {
                values.append("on update \(onUpdateExpression)")
            }
            if !isVisible { values.append("invisible") }
            return values.joined(separator: " ")
        }

        public var defaultPreset: DefaultPreset {
            switch defaultMode {
            case .none:
                .none
            case .null:
                .null
            case .expression:
                switch defaultValue.uppercased() {
                case "CURRENT_TIMESTAMP": .currentTimestamp
                case "NOW()": .now
                default: .custom
                }
            case .value:
                .custom
            }
        }

        public var extraPreset: ExtraPreset {
            switch extraDisplayValue.lowercased() {
            case "": .none
            case "auto_increment": .autoIncrement
            case "on update current_timestamp": .onUpdateCurrentTimestamp
            case "invisible": .invisible
            default: .custom
            }
        }

        public mutating func applyDefaultPreset(_ preset: DefaultPreset) {
            switch preset {
            case .none:
                defaultMode = .none
                defaultValue = ""
            case .null:
                defaultMode = .null
                defaultValue = ""
            case .currentTimestamp:
                defaultMode = .expression
                defaultValue = "CURRENT_TIMESTAMP"
            case .now:
                defaultMode = .expression
                defaultValue = "NOW()"
            case .custom:
                if defaultMode == .none || defaultMode == .null {
                    defaultMode = .value
                    defaultValue = ""
                }
            }
        }

        public mutating func applyExtraPreset(_ preset: ExtraPreset) {
            switch preset {
            case .none:
                applyExtraDisplayValue("")
            case .autoIncrement:
                applyExtraDisplayValue("auto_increment")
            case .onUpdateCurrentTimestamp:
                applyExtraDisplayValue("on update CURRENT_TIMESTAMP")
            case .invisible:
                applyExtraDisplayValue("invisible")
            case .custom:
                break
            }
        }

        public mutating func applyCharacterSet(
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

        public mutating func applyCollation(
            _ value: String,
            choices: WorkspaceDatabaseSchemaChoices
        ) {
            collation = value
            guard !value.isEmpty else { return }
            characterSet = choices.characterSet(forCollation: value)
                ?? Self.characterSet(from: value)
        }

        public mutating func applyExtraDisplayValue(_ value: String) {
            isAutoIncrement = value.localizedCaseInsensitiveContains(
                "auto_increment"
            )
            isVisible = !value.localizedCaseInsensitiveContains("invisible")
            onUpdateExpression = Self.onUpdateExpression(from: value)
        }

        public mutating func applyGeneratedStorage(_ storage: GeneratedStorage) {
            generatedStorage = storage
            guard storage != .none else {
                generationExpression = ""
                return
            }
            defaultMode = .none
            defaultValue = ""
            onUpdateExpression = ""
            isAutoIncrement = false
        }

        public mutating func applyTypeSemantics() {
            guard !supportsCharacterSetAndCollation else { return }
            characterSet = ""
            collation = ""
        }

        public mutating func applyPrimaryKeyConstraint() {
            isNullable = false
            if defaultMode == .null {
                defaultMode = .none
                defaultValue = ""
            }
        }
    }

    public struct ColumnItem: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let original: WorkspaceDatabaseColumn?
        public var definition: ColumnDefinition
        public var isDeleted: Bool

        public var isNew: Bool { original == nil }
        public var isModified: Bool {
            guard let original else { return true }
            return definition != ColumnDefinition(column: original)
        }
        public var isEditable: Bool { true }

        public init(column: WorkspaceDatabaseColumn) {
            id = UUID()
            original = column
            definition = ColumnDefinition(column: column)
            isDeleted = false
        }

        public init(defaultType: String = "VARCHAR(255)") {
            id = UUID()
            original = nil
            definition = ColumnDefinition(type: defaultType)
            isDeleted = false
        }

        public init(definition: ColumnDefinition) {
            id = UUID()
            original = nil
            self.definition = definition
            isDeleted = false
        }
    }

    public struct IndexColumnDefinition: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var prefixLength: String
        public var isDescending: Bool
        public var isExpression: Bool
        public var sourceColumnID: UUID?

        public init(column: WorkspaceDatabaseIndexColumn) {
            id = UUID()
            name = column.name
            prefixLength = column.prefixLength.map(String.init) ?? ""
            isDescending = column.direction == "D"
            isExpression = column.isExpression
            sourceColumnID = nil
        }

        public init(name: String = "", sourceColumnID: UUID? = nil) {
            id = UUID()
            self.name = name
            prefixLength = ""
            isDescending = false
            isExpression = false
            self.sourceColumnID = sourceColumnID
        }
    }

    public enum IndexKind: String, CaseIterable, Identifiable, Sendable {
        case primary
        case unique
        case normal
        case fulltext
        case spatial

        public var id: Self { self }
    }

    public struct IndexDefinition: Equatable, Sendable {
        public var name: String
        public var kind: IndexKind
        public var method: String
        public var columns: [IndexColumnDefinition]
        public var isVisible: Bool
        public var comment: String

        public init(index: WorkspaceDatabaseIndex) {
            name = index.name
            switch index.type.uppercased() {
            case "FULLTEXT":
                kind = .fulltext
                method = ""
            case "SPATIAL":
                kind = .spatial
                method = ""
            default:
                kind = index.isPrimary || index.name == "PRIMARY"
                    ? .primary
                    : (index.isUnique ? .unique : .normal)
                method = index.type.isEmpty ? "BTREE" : index.type
            }
            columns = index.columns.map(IndexColumnDefinition.init)
            isVisible = index.isVisible
            comment = index.comment
        }

        public init(firstColumnName: String?, method: String = "BTREE") {
            name = ""
            kind = .normal
            self.method = method
            columns = [IndexColumnDefinition(name: firstColumnName ?? "")]
            isVisible = true
            comment = ""
        }

        public func matches(_ index: WorkspaceDatabaseIndex) -> Bool {
            let expectedKind: IndexKind
            let expectedMethod: String
            switch index.type.uppercased() {
            case "FULLTEXT":
                expectedKind = .fulltext
                expectedMethod = ""
            case "SPATIAL":
                expectedKind = .spatial
                expectedMethod = ""
            default:
                expectedKind = index.isPrimary || index.name == "PRIMARY"
                    ? .primary
                    : (index.isUnique ? .unique : .normal)
                expectedMethod = index.type.isEmpty ? "BTREE" : index.type
            }
            guard
                name == index.name,
                kind == expectedKind,
                method.caseInsensitiveCompare(expectedMethod) == .orderedSame,
                isVisible == index.isVisible,
                comment == index.comment,
                columns.count == index.columns.count
            else {
                return false
            }
            return zip(columns, index.columns).allSatisfy { definition, column in
                definition.name == column.name
                    && definition.prefixLength
                        == column.prefixLength.map(String.init) ?? ""
                    && definition.isDescending == (column.direction == "D")
                    && definition.isExpression == column.isExpression
            }
        }
    }

    public struct IndexItem: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let original: WorkspaceDatabaseIndex?
        public var definition: IndexDefinition
        public var isDeleted: Bool

        public var isNew: Bool { original == nil }
        public var isModified: Bool {
            guard let original else { return true }
            return !definition.matches(original)
        }

        public init(index: WorkspaceDatabaseIndex) {
            id = UUID()
            original = index
            definition = IndexDefinition(index: index)
            isDeleted = false
        }

        public init(firstColumnName: String?, method: String = "BTREE") {
            id = UUID()
            original = nil
            definition = IndexDefinition(
                firstColumnName: firstColumnName,
                method: method
            )
            isDeleted = false
        }

        public init(definition: IndexDefinition) {
            id = UUID()
            original = nil
            self.definition = definition
            isDeleted = false
        }
    }

    private(set) var columns: [ColumnItem] = []
    private(set) var indexes: [IndexItem] = []
    private(set) var schemaChoices: WorkspaceDatabaseSchemaChoices = .empty
    var tableOptions = WorkspaceDatabaseTableOptions()
    private var originalTableOptions: WorkspaceDatabaseTableOptions?
    private var loadedColumns = false
    private var loadedIndexes = false

    var hasChanges: Bool {
        hasColumnChanges || hasIndexChanges || tableOptionsChange != nil
    }

    var tableOptionsChange: WorkspaceDatabaseTableOptionsChange? {
        guard let originalTableOptions, tableOptions != originalTableOptions else {
            return nil
        }
        return WorkspaceDatabaseTableOptionsChange(
            original: originalTableOptions,
            updated: tableOptions
        )
    }

    private var hasColumnChanges: Bool {
        columns.contains { $0.isDeleted || $0.isModified }
    }

    private var hasIndexChanges: Bool {
        indexes.contains { $0.isDeleted || $0.isModified }
    }

    mutating func loadColumnsIfNeeded(
        _ columns: [WorkspaceDatabaseColumn],
        schemaChoices: WorkspaceDatabaseSchemaChoices = .empty
    ) {
        self.schemaChoices = schemaChoices
        guard !loadedColumns || !hasColumnChanges else { return }
        self.columns = columns.map(ColumnItem.init)
        loadedColumns = true
    }

    mutating func loadIndexesIfNeeded(_ indexes: [WorkspaceDatabaseIndex]) {
        guard !loadedIndexes || !hasIndexChanges else { return }
        self.indexes = indexes.map(IndexItem.init)
        loadedIndexes = true
    }

    mutating func updateSchemaChoices(
        _ schemaChoices: WorkspaceDatabaseSchemaChoices
    ) {
        self.schemaChoices = schemaChoices
    }

    mutating func loadTableOptionsIfNeeded(
        _ options: WorkspaceDatabaseTableOptions
    ) {
        guard originalTableOptions == nil || tableOptionsChange == nil else {
            return
        }
        originalTableOptions = options
        tableOptions = options
    }

    mutating func addColumn(defaultType: String = "VARCHAR(255)") -> UUID {
        let item = ColumnItem(defaultType: defaultType)
        columns.append(item)
        return item.id
    }

    mutating func updateColumn(id: UUID, definition: ColumnDefinition) {
        guard let editedColumnIndex = columns.firstIndex(where: { $0.id == id })
        else { return }
        var definition = definition
        definition.applyTypeSemantics()
        if isPrimaryKey(columnID: id) {
            definition.applyPrimaryKeyConstraint()
        }
        let previousName = columns[editedColumnIndex].definition.name
        columns[editedColumnIndex].definition = definition
        guard previousName != definition.name else { return }
        for indexIndex in indexes.indices where !indexes[indexIndex].isDeleted {
            for indexColumnIndex in indexes[indexIndex].definition.columns.indices
                where indexes[indexIndex].definition.columns[indexColumnIndex]
                    .sourceColumnID == id
                    || (columns[editedColumnIndex].original != nil
                        && indexes[indexIndex].definition.columns[indexColumnIndex]
                            .sourceColumnID == nil
                        && indexes[indexIndex].definition.columns[indexColumnIndex].name
                            == previousName)
            {
                indexes[indexIndex].definition.columns[indexColumnIndex].name =
                    definition.name
            }
        }
    }

    func isPrimaryKey(columnID: UUID) -> Bool {
        guard let column = columns.first(where: { $0.id == columnID }) else {
            return false
        }
        if column.original == nil {
            return indexes.contains { item in
                !item.isDeleted
                    && item.definition.kind == .primary
                    && item.definition.columns.contains {
                        $0.sourceColumnID == columnID
                    }
            }
        }
        let names = Set([column.definition.name, column.original?.name].compactMap {
            $0
        })
        return indexes.contains { item in
            !item.isDeleted
                && item.definition.kind == .primary
                && item.definition.columns.contains {
                    $0.sourceColumnID == columnID
                        || ($0.sourceColumnID == nil && names.contains($0.name))
                }
        }
    }

    mutating func setPrimaryKey(columnID: UUID, isEnabled: Bool) {
        guard let columnIndex = columns.firstIndex(where: {
            $0.id == columnID
        }) else {
            return
        }
        if isEnabled {
            columns[columnIndex].definition.applyPrimaryKeyConstraint()
        }
        let column = columns[columnIndex]
        let currentName = column.definition.name
        let matchingNames = Set([currentName, column.original?.name].compactMap { $0 })
        if let primaryIndex = indexes.firstIndex(where: {
            $0.definition.kind == .primary && !$0.isDeleted
        }) {
            let containsColumn = indexes[primaryIndex].definition.columns.contains {
                $0.sourceColumnID == columnID
                    || (column.original != nil
                        && $0.sourceColumnID == nil
                        && matchingNames.contains($0.name))
            }
            if isEnabled, !containsColumn {
                indexes[primaryIndex].definition.columns.append(
                    IndexColumnDefinition(
                        name: currentName,
                        sourceColumnID: columnID
                    )
                )
            } else if !isEnabled, containsColumn {
                indexes[primaryIndex].definition.columns.removeAll {
                    $0.sourceColumnID == columnID
                        || (column.original != nil
                            && $0.sourceColumnID == nil
                            && matchingNames.contains($0.name))
                }
                if indexes[primaryIndex].definition.columns.isEmpty {
                    if indexes[primaryIndex].isNew {
                        indexes.remove(at: primaryIndex)
                    } else {
                        indexes[primaryIndex].isDeleted = true
                    }
                }
            }
            return
        }

        guard isEnabled else { return }
        var definition = IndexDefinition(firstColumnName: currentName)
        definition.name = "PRIMARY"
        definition.kind = .primary
        definition.columns = [
            IndexColumnDefinition(
                name: currentName,
                sourceColumnID: columnID
            ),
        ]
        indexes.append(IndexItem(definition: definition))
    }

    mutating func duplicateColumn(id: UUID) -> UUID? {
        guard
            let index = columns.firstIndex(where: { $0.id == id }),
            !columns[index].isDeleted
        else {
            return nil
        }
        var definition = columns[index].definition
        definition.name = uniqueCopyName(
            for: definition.name,
            existingNames: columns.map(\.definition.name)
        )
        let item = ColumnItem(definition: definition)
        columns.insert(item, at: index + 1)
        return item.id
    }

    @discardableResult
    mutating func deleteColumn(id: UUID) -> UUID? {
        guard let index = columns.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        if columns[index].isNew {
            columns.remove(at: index)
        } else {
            columns[index].isDeleted = true
        }
        return Self.nearestActiveID(
            in: columns,
            startingAt: index,
            isDeleted: \.isDeleted
        )
    }

    mutating func addIndex(defaultMethod: String = "BTREE") -> UUID {
        let firstColumn = columns.first { !$0.isDeleted }?.definition.name
        let item = IndexItem(
            firstColumnName: firstColumn,
            method: defaultMethod
        )
        indexes.append(item)
        return item.id
    }

    mutating func updateIndex(id: UUID, definition: IndexDefinition) {
        guard let index = indexes.firstIndex(where: { $0.id == id }) else { return }
        indexes[index].definition = definition
    }

    mutating func duplicateIndex(id: UUID) -> UUID? {
        guard
            let index = indexes.firstIndex(where: { $0.id == id }),
            !indexes[index].isDeleted
        else {
            return nil
        }
        var definition = indexes[index].definition
        if definition.kind == .primary {
            definition.kind = .normal
        }
        definition.name = uniqueCopyName(
            for: definition.name == "PRIMARY" ? "index" : definition.name,
            existingNames: indexes.map(\.definition.name)
        )
        let item = IndexItem(definition: definition)
        indexes.insert(item, at: index + 1)
        return item.id
    }

    @discardableResult
    mutating func deleteIndex(id: UUID) -> UUID? {
        guard let index = indexes.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        if indexes[index].isNew {
            indexes.remove(at: index)
        } else {
            indexes[index].isDeleted = true
        }
        return Self.nearestActiveID(
            in: indexes,
            startingAt: index,
            isDeleted: \.isDeleted
        )
    }

    private static func nearestActiveID<Item: Identifiable>(
        in items: [Item],
        startingAt index: Int,
        isDeleted: KeyPath<Item, Bool>
    ) -> UUID? where Item.ID == UUID {
        let splitIndex = min(index, items.count)
        if let next = items.dropFirst(splitIndex).first(where: {
            !$0[keyPath: isDeleted]
        }) {
            return next.id
        }
        return items.prefix(splitIndex).reversed().first(where: {
            !$0[keyPath: isDeleted]
        })?.id
    }

    mutating func discardChanges() {
        columns = columns.compactMap { item in
            guard let original = item.original else { return nil }
            return ColumnItem(column: original)
        }
        indexes = indexes.compactMap { item in
            guard let original = item.original else { return nil }
            return IndexItem(index: original)
        }
        if let originalTableOptions {
            tableOptions = originalTableOptions
        }
    }

    mutating func reset(
        columns: [WorkspaceDatabaseColumn],
        indexes: [WorkspaceDatabaseIndex],
        schemaChoices: WorkspaceDatabaseSchemaChoices = .empty,
        tableOptions: WorkspaceDatabaseTableOptions? = nil
    ) {
        self.columns = columns.map(ColumnItem.init)
        self.indexes = indexes.map(IndexItem.init)
        self.schemaChoices = schemaChoices
        if let tableOptions {
            self.tableOptions = tableOptions
            originalTableOptions = tableOptions
        } else {
            self.tableOptions = WorkspaceDatabaseTableOptions()
            originalTableOptions = nil
        }
        loadedColumns = true
        loadedIndexes = true
    }

    private func uniqueCopyName(
        for sourceName: String,
        existingNames: [String]
    ) -> String {
        let baseName = sourceName.isEmpty ? "copy" : sourceName + "_copy"
        let existing = Set(existingNames.map { $0.lowercased() })
        if !existing.contains(baseName.lowercased()) {
            return baseName
        }
        var suffix = 2
        while existing.contains("\(baseName)\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(baseName)\(suffix)"
    }
}

public struct WorkspaceDatabaseSchemaChangeSet: Equatable, Sendable {
    public let selection: WorkspaceDatabaseObjectSelection
    public let columns: [WorkspaceDatabaseSchemaEditorState.ColumnItem]
    public let indexes: [WorkspaceDatabaseSchemaEditorState.IndexItem]
    public let tableOptionsChange: WorkspaceDatabaseTableOptionsChange?

    public init(
        selection: WorkspaceDatabaseObjectSelection,
        columns: [WorkspaceDatabaseSchemaEditorState.ColumnItem],
        indexes: [WorkspaceDatabaseSchemaEditorState.IndexItem],
        tableOptionsChange: WorkspaceDatabaseTableOptionsChange? = nil
    ) {
        self.selection = selection
        self.columns = columns
        self.indexes = indexes
        self.tableOptionsChange = tableOptionsChange
    }

    public var isEmpty: Bool {
        !columns.contains { $0.isDeleted || $0.isModified }
            && !indexes.contains { $0.isDeleted || $0.isModified }
            && tableOptionsChange == nil
    }
}

public struct WorkspaceDatabaseTableOptionsChange: Equatable, Sendable {
    public let original: WorkspaceDatabaseTableOptions
    public let updated: WorkspaceDatabaseTableOptions

    public init(
        original: WorkspaceDatabaseTableOptions,
        updated: WorkspaceDatabaseTableOptions
    ) {
        self.original = original
        self.updated = updated
    }
}
