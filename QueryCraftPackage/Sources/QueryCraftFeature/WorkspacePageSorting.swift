import Foundation

enum WorkspacePageSorting {
    static func sorted(_ page: WorkspaceDatabaseDataPage, by sort: WorkspaceDatabaseDataSort) -> WorkspaceDatabaseDataPage {
        guard let name = sort.columnName, let column = page.columns.first(where: { $0.name == name }) else { return page }
        guard !page.rows.contains(where: { if case .binary = $0.value(at: column.id) { true } else { false } }) else { return page }
        let type = (column.type ?? "").lowercased()
        let numeric = ["int", "bigint", "smallint", "tinyint", "mediumint", "float", "double", "decimal", "numeric", "real", "serial", "number"].contains { type.hasPrefix($0) }
        let ascending: Bool
        if case .ascending = sort { ascending = true } else { ascending = false }
        let rows = page.rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.value(at: column.id), right = rhs.element.value(at: column.id)
            let result: ComparisonResult
            switch (left, right) {
            case (.null, .null): result = .orderedSame
            case (.null, _): result = .orderedAscending
            case (_, .null): result = .orderedDescending
            case let (.text(a), .text(b)):
                if numeric, let x = Decimal(string: a, locale: Locale(identifier: "en_US_POSIX")),
                   let y = Decimal(string: b, locale: Locale(identifier: "en_US_POSIX")) {
                    result = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
                } else { result = a.compare(b, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            default: result = .orderedSame
            }
            if result == .orderedSame { return lhs.offset < rhs.offset }
            return result == (ascending ? .orderedAscending : .orderedDescending)
        }.map(\.element)
        var result = WorkspaceDatabaseDataPage(columns: page.columns, rows: rows, offset: page.offset,
            limit: page.limit, hasNextPage: page.hasNextPage, sort: page.sort, filter: page.filter)
        result.localSort = sort
        return result
    }
}
