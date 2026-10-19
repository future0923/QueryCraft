import Foundation

struct SchemaComparisonAttribute: Equatable, Identifiable, Sendable {
    let key: String
    let source: String
    let target: String
    var id: String { key }
    var title: String {
        let copy = AppCopy.current
        switch key {
        case "type": return copy.text("类型", "Type")
        case "nullable": return copy.text("允许 NULL", "Nullable")
        case "default": return copy.text("默认值", "Default")
        case "collation": return copy.text("排序规则", "Collation")
        case "comment": return copy.text("注释", "Comment")
        case "extra": return copy.text("附加属性", "Extra")
        case "generated": return copy.text("生成表达式", "Generated Expression")
        case "dependency": return copy.text("依赖调整", "Dependency Change")
        case "name": return copy.text("名称", "Name")
        case "order": return copy.text("字段顺序", "Column Order")
        case "columns", "column_pairs": return copy.text("关联字段", "Columns")
        case "character_set": return copy.text("字符集", "Character Set")
        case "is_primary": return copy.text("主键", "Primary Key")
        case "is_unique": return copy.text("唯一性", "Unique")
        case "index_type": return copy.text("索引类型", "Index Type")
        case "ref_table", "ref_schema": return copy.text("引用对象", "Reference")
        case "on_delete": return copy.text("删除规则", "On Delete")
        case "on_update": return copy.text("更新规则", "On Update")
        case "action_order": return copy.text("触发顺序", "Trigger Order")
        case "timing": return copy.text("触发时机", "Timing")
        case "event": return copy.text("触发事件", "Event")
        case "statement": return copy.text("触发器定义", "Trigger Body")
        case "presence": return copy.text("对象", "Object")
        case "ENGINE": return copy.text("存储引擎", "Engine")
        case "CHARSET": return copy.text("字符集", "Character Set")
        case "COLLATE": return copy.text("排序规则", "Collation")
        case "COMMENT": return copy.text("注释", "Comment")
        default: return copy.text("定义", "Definition")
        }
    }
    var summary: String { "\(title)：\(target) → \(source)" }
}

/// Compare actual catalog attributes. Original DDL remains the source for SQL
/// generation; a semantic match never broadens the set of exportable clauses.
enum SchemaComparisonSemantics {
    static func columnAttributes(source: WorkspaceDatabaseColumn?, target: WorkspaceDatabaseColumn?,
                                 sourcePart: MySQLSchemaDefinition.Part?, targetPart: MySQLSchemaDefinition.Part?,
                                 options: SchemaComparisonOptions) -> [SchemaComparisonAttribute] {
        let copy = AppCopy.current
        let yes = copy.text("是", "Yes"), no = copy.text("否", "No")
        func values(_ column: WorkspaceDatabaseColumn?, _ part: MySQLSchemaDefinition.Part?) -> [String: String] {
            guard let column else { return [:] }
            return ["type": column.type, "nullable": column.isNullable ? yes : no,
                    "default": defaultValue(column, part: part), "collation": column.collation ?? "",
                    "comment": column.comment, "extra": extra(column.extra), "generated": column.generationExpression]
        }
        let s = values(source, sourcePart), t = values(target, targetPart)
        return ["type", "nullable", "default", "collation", "comment", "extra", "generated"].compactMap { key in
            if key == "comment" && options.ignoresComments { return nil }
            let a = s[key], b = t[key]
            let equal: Bool
            if key == "type", let a, let b { equal = typesEqual(a, b) }
            else if ["collation", "extra"].contains(key), let a, let b { equal = a.caseInsensitiveCompare(b) == .orderedSame }
            else { equal = a == b }
            guard !equal, !(a ?? "").isEmpty || !(b ?? "").isEmpty else { return nil }
            return .init(key: key, source: a.flatMap { $0.isEmpty ? nil : $0 } ?? "—",
                         target: b.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        }
    }

    static func typesEqual(_ source: String, _ target: String) -> Bool {
        guard let a = try? MySQLSchemaDefinition.tokenize(source).map(MySQLSchemaDefinition.canonicalToken),
              let b = try? MySQLSchemaDefinition.tokenize(target).map(MySQLSchemaDefinition.canonicalToken) else {
            return source == target
        }
        func integer(_ tokens: [String]) -> (tokens: [String], width: String?) {
            guard let first = tokens.first,
                  ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT", "YEAR"].contains(first),
                  !tokens.contains("ZEROFILL") else { return (tokens, nil) }
            guard tokens.count >= 4, tokens[1] == "(", tokens[2].allSatisfy(\.isNumber), tokens[3] == ")" else {
                return (tokens, nil)
            }
            return ([first] + tokens.dropFirst(4), tokens[2])
        }
        let x = integer(a), y = integer(b)
        return x.tokens == y.tokens && (x.width == nil || y.width == nil || x.width == y.width)
    }

    private static func extra(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).filter { $0.uppercased() != "DEFAULT_GENERATED" }.joined(separator: " ")
    }

    private static func defaultValue(_ column: WorkspaceDatabaseColumn, part: MySQLSchemaDefinition.Part?) -> String {
        guard let value = column.defaultValue else {
            return column.isNullable ? "NULL" : AppCopy.current.text("未设置", "Not Set")
        }
        if let tokens = part?.canonical, let i = tokens.firstIndex(of: "DEFAULT"), tokens.indices.contains(i + 1),
           tokens[i + 1].hasPrefix("'") {
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        // MySQL 8 adds parentheses to this expression. A quoted string with
        // the same spelling remains a literal and must never be normalized.
        if let tokens = part?.canonical, let i = tokens.firstIndex(of: "DEFAULT"), tokens.indices.contains(i + 1),
           tokens[i + 1] == "CURRENT_TIMESTAMP", ["CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP()"].contains(value.uppercased()) {
            return "CURRENT_TIMESTAMP"
        }
        return value
    }
}

extension SchemaComparisonDifference {
    var operationTitle: String {
        let copy = AppCopy.current
        switch status {
        case .added: return copy.text("新增", "Add")
        case .targetOnly: return copy.text("删除", "Remove")
        case .modified: return copy.text("修改", "Modify")
        case .equal: return copy.text("一致", "Equal")
        case .unavailable: return copy.text("未完成", "Incomplete")
        }
    }
    var changeSummary: String {
        if !attributes.isEmpty { return attributes.map(\.summary).joined(separator: "；") }
        let copy = AppCopy.current
        switch status {
        case .added: return copy.text("目标缺少此\(kindTitle)", "Missing from target: \(kindTitle)")
        case .targetOnly: return copy.text("此\(kindTitle)仅存在于目标", "Only in target: \(kindTitle)")
        case .modified: return copy.text("\(kindTitle)定义不同", "\(kindTitle) definition differs")
        case .equal: return copy.text("定义一致", "Definitions match")
        case .unavailable: return explanation
        }
    }
}
