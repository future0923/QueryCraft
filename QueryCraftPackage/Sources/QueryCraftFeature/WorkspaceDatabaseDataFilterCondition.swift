import Foundation

public struct WorkspaceDatabaseDataFilterCondition: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var isEnabled: Bool
    public var columnName: String
    public var columnKind: WorkspaceDatabaseDataFilterColumnKind
    public var elasticsearchClause: WorkspaceElasticsearchBoolClause
    public var operation: WorkspaceDatabaseDataFilterOperator
    public var value: String
    public var secondValue: String

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        columnName: String,
        columnKind: WorkspaceDatabaseDataFilterColumnKind,
        elasticsearchClause: WorkspaceElasticsearchBoolClause = .filter,
        operation: WorkspaceDatabaseDataFilterOperator = .equal,
        value: String = "",
        secondValue: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.columnName = columnName
        self.columnKind = columnKind
        self.elasticsearchClause = elasticsearchClause
        self.operation = operation
        self.value = value
        self.secondValue = secondValue
    }

    public var isValid: Bool {
        guard !columnName.isEmpty else { return false }
        guard WorkspaceDatabaseDataFilterOperator.available(for: columnKind)
            .contains(operation)
        else {
            return false
        }
        guard operation.requiresValue else { return true }
        if operation == .terms {
            return isValidTerms(value)
        }
        guard isValid(value) else { return false }
        return !operation.requiresSecondValue || isValid(secondValue)
    }

    mutating func selectElasticsearchField(
        name: String,
        kind: WorkspaceDatabaseDataFilterColumnKind
    ) {
        columnName = name
        columnKind = kind
        let operators = WorkspaceDatabaseDataFilterOperator.available(for: kind)
        if !operators.contains(operation), let first = operators.first {
            operation = first
        }
        value = ""
        secondValue = ""
        isEnabled = true
    }

    private func isValid(_ candidate: String) -> Bool {
        switch columnKind {
        case .number, .elasticsearchNumber:
            candidate.range(
                of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                options: .regularExpression
            ) != nil
        case .elasticsearchBoolean:
            candidate == "true" || candidate == "false"
        case .date, .enumeration, .boolean, .binary, .text,
             .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchDate,
             .elasticsearchIP:
            true
        }
    }

    private func isValidTerms(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("[") {
            guard
                let data = trimmed.data(using: .utf8),
                let values = try? JSONSerialization.jsonObject(with: data)
                    as? [Any],
                !values.isEmpty
            else {
                return false
            }
            return values.allSatisfy(isValidTermsScalar)
        }

        let values = trimmed.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !values.isEmpty && values.allSatisfy(isValid)
    }

    private func isValidTermsScalar(_ value: Any) -> Bool {
        guard !(value is NSNull) else { return false }
        if let string = value as? String {
            return isValid(string)
        }
        if let number = value as? NSNumber {
            switch columnKind {
            case .elasticsearchBoolean:
                return CFGetTypeID(number) == CFBooleanGetTypeID()
            case .number, .elasticsearchNumber:
                return CFGetTypeID(number) != CFBooleanGetTypeID()
                    && isValid(number.stringValue)
            case .date, .enumeration, .boolean, .binary, .text,
                 .elasticsearchKeyword, .elasticsearchText,
                 .elasticsearchTextWithKeyword, .elasticsearchDate,
                 .elasticsearchIP:
                return true
            }
        }
        return false
    }
}
