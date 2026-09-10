extension WorkspaceDatabaseDataFilterLogic {
    var title: String {
        switch self {
        case .matchAll:
            AppCopy.current.text("全部匹配", "Match All")
        case .matchAny:
            AppCopy.current.text("任一匹配", "Match Any")
        }
    }
}

extension WorkspaceDatabaseDataFilterOperator {
    var title: String {
        switch self {
        case .equal:
            AppCopy.current.text("等于", "Equals")
        case .notEqual:
            AppCopy.current.text("不等于", "Does Not Equal")
        case .contains:
            AppCopy.current.text("包含", "Contains")
        case .startsWith:
            AppCopy.current.text("开头是", "Starts With")
        case .endsWith:
            AppCopy.current.text("结尾是", "Ends With")
        case .lessThan:
            AppCopy.current.text("小于", "Less Than")
        case .lessThanOrEqual:
            AppCopy.current.text("小于或等于", "Less Than or Equal")
        case .greaterThan:
            AppCopy.current.text("大于", "Greater Than")
        case .greaterThanOrEqual:
            AppCopy.current.text("大于或等于", "Greater Than or Equal")
        case .between:
            AppCopy.current.text("介于", "Between")
        case .isNull:
            AppCopy.current.text("为空值", "Is NULL")
        case .isNotNull:
            AppCopy.current.text("不为空值", "Is Not NULL")
        case .term:
            AppCopy.current.text("term", "term")
        case .terms:
            AppCopy.current.text("terms", "terms")
        case .match:
            AppCopy.current.text("match", "match")
        case .matchPhrase:
            AppCopy.current.text("match_phrase", "match_phrase")
        case .wildcard:
            AppCopy.current.text("wildcard", "wildcard")
        case .rangeLessThan:
            AppCopy.current.text("range <", "range <")
        case .rangeLessThanOrEqual:
            AppCopy.current.text("range ≤", "range ≤")
        case .rangeGreaterThan:
            AppCopy.current.text("range >", "range >")
        case .rangeGreaterThanOrEqual:
            AppCopy.current.text("range ≥", "range ≥")
        case .exists:
            AppCopy.current.text("exists", "exists")
        }
    }
}
