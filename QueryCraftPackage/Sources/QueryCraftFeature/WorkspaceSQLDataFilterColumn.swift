import Foundation

/// The same SQL field defaults and enum/bool choices on every platform.
public enum WorkspaceSQLDataFilterColumn {
    public static func menuValues(type: String, kind: WorkspaceDatabaseDataFilterColumnKind) -> [String] {
        switch kind {
        case .boolean: return ["0", "1"]
        case .elasticsearchBoolean: return ["false", "true"]
        case .enumeration: return parseEnumerationValues(from: type)
        default: return []
        }
    }

    public static func defaultCondition(name: String, type: String, kind: WorkspaceDatabaseDataFilterColumnKind) -> WorkspaceDatabaseDataFilterCondition {
        .init(columnName: name, columnKind: kind,
              operation: WorkspaceDatabaseDataFilterOperator.available(for: kind)[0],
              value: kind.isElasticsearch ? "" : menuValues(type: type, kind: kind).first ?? "")
    }

    public static func selectColumn(_ condition: inout WorkspaceDatabaseDataFilterCondition, name: String, type: String, kind: WorkspaceDatabaseDataFilterColumnKind) {
        condition.columnName = name
        condition.columnKind = kind
        let operators = WorkspaceDatabaseDataFilterOperator.available(for: kind)
        if !operators.contains(condition.operation) { condition.operation = operators[0] }
        condition.value = menuValues(type: type, kind: kind).first ?? ""
        condition.secondValue = ""
    }

    private static func parseEnumerationValues(from mysqlType: String) -> [String] {
        guard let opening = mysqlType.firstIndex(of: "("), let closing = mysqlType.lastIndex(of: ")"), opening < closing else { return [] }
        let body = mysqlType[mysqlType.index(after: opening)..<closing]
        var values: [String] = [], current = "", isQuoted = false, isEscaped = false
        for character in body {
            if isEscaped { current.append(character); isEscaped = false }
            else if character == "\\" && isQuoted { isEscaped = true }
            else if character == "'" {
                if isQuoted { values.append(current); current = "" }
                isQuoted.toggle()
            } else if isQuoted { current.append(character) }
        }
        return values
    }
}
