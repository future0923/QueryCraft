import Foundation
#if os(iOS)
import QueryCraftMobileCore
#else
import QueryCraftFeature
#endif

/// One predicate generator for the desktop driver and the bounded mobile reader.
/// The desktop retains transport bindings; mobile uses mode-independent UTF-8
/// literals because its streaming preview API intentionally has no bind step.
struct MySQLDataFilterPredicate: Sendable {
    enum Values { case bindings, literals, dorisLiterals }
    let sql: String
    let bindings: [WorkspaceDatabaseDataCell]

    static func make(_ filter: WorkspaceDatabaseDataFilter, values: Values = .bindings) throws -> Self {
        let conditions = filter.enabledConditions
        guard !conditions.isEmpty else { return .init(sql: "", bindings: []) }
        guard filter.isValid else { throw WorkspaceSessionError.invalidDataFilter }
        var predicates: [String] = []
        var bindings: [WorkspaceDatabaseDataCell] = []
        predicates.reserveCapacity(conditions.count)
        func parameter(_ value: String) -> String {
            switch values {
            case .bindings: bindings.append(.text(value)); return "?"
            case .dorisLiterals:
                return "UNHEX('" + value.utf8.map { String(format: "%02x", $0) }.joined() + "')"
            case .literals:
                guard !value.isEmpty else { return "''" }
                return "CONVERT(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)"
            }
        }
        for condition in conditions {
            let column = "`" + condition.columnName.replacingOccurrences(of: "`", with: "``") + "`"
            let predicate: String
            switch condition.operation {
            case .equal: predicate = "\(column) = \(parameter(condition.value))"
            case .notEqual: predicate = "\(column) <> \(parameter(condition.value))"
            case .contains: predicate = "\(column) LIKE \(parameter("%" + escapedLike(condition.value) + "%")) ESCAPE 0x5c"
            case .startsWith: predicate = "\(column) LIKE \(parameter(escapedLike(condition.value) + "%")) ESCAPE 0x5c"
            case .endsWith: predicate = "\(column) LIKE \(parameter("%" + escapedLike(condition.value))) ESCAPE 0x5c"
            case .lessThan: predicate = "\(column) < \(parameter(condition.value))"
            case .lessThanOrEqual: predicate = "\(column) <= \(parameter(condition.value))"
            case .greaterThan: predicate = "\(column) > \(parameter(condition.value))"
            case .greaterThanOrEqual: predicate = "\(column) >= \(parameter(condition.value))"
            case .between: predicate = "\(column) BETWEEN \(parameter(condition.value)) AND \(parameter(condition.secondValue))"
            case .isNull: predicate = "\(column) IS NULL"
            case .isNotNull: predicate = "\(column) IS NOT NULL"
            case .term, .terms, .match, .matchPhrase, .wildcard,
                 .rangeLessThan, .rangeLessThanOrEqual, .rangeGreaterThan, .rangeGreaterThanOrEqual, .exists:
                throw WorkspaceSessionError.invalidDataFilter
            }
            predicates.append("(\(predicate))")
        }
        return .init(sql: " WHERE " + predicates.joined(separator: filter.logic == .matchAll ? " AND " : " OR "), bindings: bindings)
    }

    private static func escapedLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
