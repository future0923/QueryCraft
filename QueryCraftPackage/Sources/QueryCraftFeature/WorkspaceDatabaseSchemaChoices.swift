public struct WorkspaceDatabaseSchemaChoices: Equatable, Sendable {
    public struct Collation: Equatable, Sendable {
        public let name: String
        public let characterSet: String
        public let isDefault: Bool

        public init(
            name: String,
            characterSet: String,
            isDefault: Bool
        ) {
            self.name = name
            self.characterSet = characterSet
            self.isDefault = isDefault
        }
    }

    public static let empty = Self(engines: [], characterSets: [], collations: [])

    public let engines: [String]
    public let characterSets: [String]
    public let collations: [Collation]

    public init(
        engines: [String] = [],
        characterSets: [String],
        collations: [Collation]
    ) {
        self.engines = engines
        self.characterSets = characterSets
        self.collations = collations
    }

    public func characterSet(forCollation name: String) -> String? {
        collations.first { $0.name == name }?.characterSet
    }

    public func defaultCollation(forCharacterSet name: String) -> String? {
        collations.first {
            $0.characterSet == name && $0.isDefault
        }?.name
    }

    public func contains(_ collation: String, inCharacterSet characterSet: String) -> Bool {
        collations.contains {
            $0.name == collation && $0.characterSet == characterSet
        }
    }
}
