public enum WorkspaceDatabaseDataSort: Equatable, Hashable, Sendable {
    case none
    case ascending(columnName: String)
    case descending(columnName: String)

    var columnName: String? {
        switch self {
        case .none:
            nil
        case let .ascending(columnName), let .descending(columnName):
            columnName
        }
    }

    func toggled(for columnName: String) -> Self {
        switch self {
        case .descending(columnName: columnName):
            .ascending(columnName: columnName)
        case .ascending(columnName: columnName):
            .none
        case .none, .ascending, .descending:
            .descending(columnName: columnName)
        }
    }

    static func defaultForTable(
        columns: [WorkspaceDatabaseColumn]
    ) -> Self {
        guard let primaryKey = columns.first(where: {
            $0.key.caseInsensitiveCompare("PRI") == .orderedSame
        }) else {
            return .none
        }
        return .ascending(columnName: primaryKey.name)
    }
}
