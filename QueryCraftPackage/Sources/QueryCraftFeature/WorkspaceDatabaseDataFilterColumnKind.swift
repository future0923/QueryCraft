import Foundation

public enum WorkspaceDatabaseDataFilterColumnKind: String, Hashable, Sendable {
    case text
    case number
    case date
    case enumeration
    case boolean
    case binary
    case elasticsearchKeyword
    case elasticsearchText
    case elasticsearchTextWithKeyword
    case elasticsearchNumber
    case elasticsearchDate
    case elasticsearchIP
    case elasticsearchBoolean

    var isElasticsearch: Bool {
        switch self {
        case .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchNumber,
             .elasticsearchDate, .elasticsearchIP, .elasticsearchBoolean:
            true
        case .text, .number, .date, .enumeration, .boolean, .binary:
            false
        }
    }

    public init(mysqlType: String) {
        let normalized = mysqlType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("enum(") || normalized.hasPrefix("set(") {
            self = .enumeration
        } else if normalized == "bool" || normalized == "boolean"
                    || normalized.hasPrefix("tinyint(1)") {
            self = .boolean
        } else if normalized.contains("binary")
                    || normalized.contains("blob")
                    || normalized == "bytea"
                    || normalized.hasPrefix("bit(")
                    || normalized.hasPrefix("geometry") {
            self = .binary
        } else if normalized.hasPrefix("date")
                    || normalized.hasPrefix("datetime")
                    || normalized.hasPrefix("timestamp")
                    || normalized.hasPrefix("time")
                    || normalized.hasPrefix("year") {
            self = .date
        } else if normalized.hasPrefix("tinyint")
                    || normalized.hasPrefix("smallint")
                    || normalized.hasPrefix("mediumint")
                    || normalized.hasPrefix("int")
                    || normalized.hasPrefix("integer")
                    || normalized.hasPrefix("bigint")
                    || normalized.hasPrefix("decimal")
                    || normalized.hasPrefix("numeric")
                    || normalized.hasPrefix("float")
                    || normalized.hasPrefix("double")
                    || normalized.hasPrefix("real")
                    || normalized.hasPrefix("smallserial")
                    || normalized.hasPrefix("serial")
                    || normalized.hasPrefix("bigserial") {
            self = .number
        } else {
            self = .text
        }
    }

    init?(elasticsearchType: String, hasKeywordSubfield: Bool) {
        switch elasticsearchType.lowercased() {
        case "keyword", "constant_keyword", "wildcard", "version":
            self = .elasticsearchKeyword
        case "text", "match_only_text", "search_as_you_type":
            self = hasKeywordSubfield
                ? .elasticsearchTextWithKeyword
                : .elasticsearchText
        case "byte", "short", "integer", "long", "unsigned_long",
             "half_float", "float", "double", "scaled_float", "token_count":
            self = .elasticsearchNumber
        case "date", "date_nanos":
            self = .elasticsearchDate
        case "ip":
            self = .elasticsearchIP
        case "boolean":
            self = .elasticsearchBoolean
        default:
            return nil
        }
    }
}
