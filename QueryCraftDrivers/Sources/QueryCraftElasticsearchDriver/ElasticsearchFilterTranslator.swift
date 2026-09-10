import Foundation
import QueryCraftFeature

enum ElasticsearchFilterTranslator {
    static func query(
        for filter: WorkspaceDatabaseDataFilter,
        mapping: ElasticsearchMappingCatalog
    ) throws -> [String: Any] {
        var buckets: [WorkspaceElasticsearchBoolClause: [[String: Any]]] = [:]
        for condition in filter.conditions {
            let query = try clause(for: condition, mapping: mapping)
            buckets[condition.elasticsearchClause, default: []].append(query)
        }
        guard !buckets.isEmpty else { return ["match_all": [:]] }

        var bool: [String: Any] = [:]
        for clause in WorkspaceElasticsearchBoolClause.allCases {
            if let queries = buckets[clause], !queries.isEmpty {
                bool[clause.rawValue] = queries
            }
        }
        if buckets[.should]?.isEmpty == false {
            bool["minimum_should_match"] = 1
        }
        return ["bool": bool]
    }

    private static func clause(
        for condition: WorkspaceDatabaseDataFilterCondition,
        mapping: ElasticsearchMappingCatalog
    ) throws -> [String: Any] {
        guard let field = mapping.byPath[condition.columnName],
              !field.hasTypeConflict,
              field.isIndexed
        else {
            throw ElasticsearchError.mappingConflict(condition.columnName)
        }
        guard condition.isValid else {
            throw WorkspaceSessionError.invalidDataFilter
        }
        let path = field.path
        switch condition.operation {
        case .exists:
            return ["exists": ["field": path]]
        case .rangeLessThan, .rangeLessThanOrEqual,
             .rangeGreaterThan, .rangeGreaterThanOrEqual:
            var bounds: [String: Any] = [:]
            switch condition.operation {
            case .rangeLessThan:
                bounds["lt"] = typed(condition.value, kind: condition.columnKind)
            case .rangeLessThanOrEqual:
                bounds["lte"] = typed(condition.value, kind: condition.columnKind)
            case .rangeGreaterThan:
                bounds["gt"] = typed(condition.value, kind: condition.columnKind)
            case .rangeGreaterThanOrEqual:
                bounds["gte"] = typed(condition.value, kind: condition.columnKind)
            default: break
            }
            return ["range": [path: bounds]]
        case .term:
            return ["term": [path: typed(
                condition.value,
                kind: condition.columnKind
            )]]
        case .terms:
            return ["terms": [
                path: try typedTerms(
                    condition.value,
                    kind: condition.columnKind
                ),
            ]]
        case .match:
            return ["match": [path: condition.value]]
        case .matchPhrase:
            return ["match_phrase": [path: condition.value]]
        case .wildcard:
            return ["wildcard": [
                path: ["value": condition.value],
            ]]
        case .equal, .notEqual, .contains, .startsWith, .endsWith,
             .lessThan, .lessThanOrEqual, .greaterThan,
             .greaterThanOrEqual, .between, .isNull, .isNotNull:
            throw WorkspaceSessionError.invalidDataFilter
        }
    }

    private static func typedTerms(
        _ value: String,
        kind: WorkspaceDatabaseDataFilterColumnKind
    ) throws -> [Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceSessionError.invalidDataFilter
        }

        if trimmed.hasPrefix("[") {
            guard
                let data = trimmed.data(using: .utf8),
                let values = try? JSONSerialization.jsonObject(with: data)
                    as? [Any],
                !values.isEmpty
            else {
                throw WorkspaceSessionError.invalidDataFilter
            }
            return try values.map { try typedJSONScalar($0, kind: kind) }
        }

        let values = trimmed.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else {
            throw WorkspaceSessionError.invalidDataFilter
        }
        return values.map { typed($0, kind: kind) }
    }

    private static func typedJSONScalar(
        _ value: Any,
        kind: WorkspaceDatabaseDataFilterColumnKind
    ) throws -> Any {
        if let string = value as? String {
            return typed(string, kind: kind)
        }
        guard let number = value as? NSNumber else {
            throw WorkspaceSessionError.invalidDataFilter
        }
        switch kind {
        case .elasticsearchBoolean:
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw WorkspaceSessionError.invalidDataFilter
            }
            return number.boolValue
        case .number, .elasticsearchNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw WorkspaceSessionError.invalidDataFilter
            }
            return typed(number.stringValue, kind: kind)
        case .date, .enumeration, .boolean, .binary, .text,
             .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchDate,
             .elasticsearchIP:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
    }

    private static func typed(
        _ value: String,
        kind: WorkspaceDatabaseDataFilterColumnKind
    ) -> Any {
        switch kind {
        case .number, .elasticsearchNumber:
            return Decimal(string: value).map { NSDecimalNumber(decimal: $0) }
                ?? value
        case .boolean, .elasticsearchBoolean:
            return (value as NSString).boolValue
        case .date, .enumeration, .binary, .text,
             .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchDate,
             .elasticsearchIP:
            return value
        }
    }
}
