public enum WorkspaceDatabaseDataFilterOperator: String, CaseIterable, Hashable, Sendable {
    case equal
    case notEqual
    case contains
    case startsWith
    case endsWith
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case between
    case isNull
    case isNotNull
    case term
    case terms
    case match
    case matchPhrase
    case wildcard
    case rangeLessThan
    case rangeLessThanOrEqual
    case rangeGreaterThan
    case rangeGreaterThanOrEqual
    case exists

    public var requiresValue: Bool {
        switch self {
        case .isNull, .isNotNull, .exists:
            false
        default:
            true
        }
    }

    public var requiresSecondValue: Bool {
        self == .between
    }

    public static func available(
        for kind: WorkspaceDatabaseDataFilterColumnKind
    ) -> [Self] {
        switch kind {
        case .text:
            [
                .equal, .notEqual, .contains, .startsWith, .endsWith,
                .isNull, .isNotNull,
            ]
        case .number, .date:
            [
                .equal, .notEqual, .lessThan, .lessThanOrEqual,
                .greaterThan, .greaterThanOrEqual, .between,
                .isNull, .isNotNull,
            ]
        case .enumeration, .boolean:
            [.equal, .notEqual, .isNull, .isNotNull]
        case .binary:
            [.equal, .notEqual, .isNull, .isNotNull]
        case .elasticsearchKeyword:
            [.term, .terms, .wildcard, .exists]
        case .elasticsearchText:
            [
                .match, .matchPhrase, .term, .wildcard, .exists,
            ]
        case .elasticsearchTextWithKeyword:
            [
                .match, .matchPhrase, .term, .wildcard, .exists,
            ]
        case .elasticsearchNumber, .elasticsearchDate, .elasticsearchIP:
            [
                .term, .terms, .rangeGreaterThan, .rangeGreaterThanOrEqual,
                .rangeLessThan, .rangeLessThanOrEqual, .exists,
            ]
        case .elasticsearchBoolean:
            [.term, .exists]
        }
    }
}
