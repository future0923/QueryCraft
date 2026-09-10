struct RedisCommandArgument: Equatable, Sendable {
    let name: String
    let kind: RedisCommandArgumentKind
    let descriptionZH: String
    let descriptionEN: String
    let isOptional: Bool

    var displayName: String {
        isOptional ? "[\(name)]" : name
    }

    @MainActor
    var description: String {
        AppCopy.current.text(descriptionZH, descriptionEN)
    }

    static func key(_ name: String = "key", optional: Bool = false) -> Self {
        .init(
            name: name,
            kind: .key,
            descriptionZH: "Redis Key，可从当前已加载的 Key 中选择",
            descriptionEN: "Redis key; choose from keys loaded for the current database",
            isOptional: optional
        )
    }

    static func field(_ name: String = "field", optional: Bool = false) -> Self {
        .init(
            name: name,
            kind: .field,
            descriptionZH: "Hash 字段名，可使用已有字段或输入新字段",
            descriptionEN: "Hash field; use an existing field or enter a new one",
            isOptional: optional
        )
    }

    static func value(_ name: String = "value", optional: Bool = false) -> Self {
        .init(
            name: name,
            kind: .value,
            descriptionZH: "要读取或写入的值",
            descriptionEN: "Value to read or write",
            isOptional: optional
        )
    }

    static func integer(_ name: String, optional: Bool = false) -> Self {
        .init(
            name: name,
            kind: .integer,
            descriptionZH: "整数参数",
            descriptionEN: "Integer argument",
            isOptional: optional
        )
    }

    static func cursor(optional: Bool = false) -> Self {
        .init(
            name: "cursor",
            kind: .cursor,
            descriptionZH: "扫描游标，首次扫描使用 0",
            descriptionEN: "Scan cursor; use 0 for the first scan",
            isOptional: optional
        )
    }

    static func pattern(optional: Bool = false) -> Self {
        .init(
            name: "pattern",
            kind: .pattern,
            descriptionZH: "匹配模式，例如 user:*",
            descriptionEN: "Match pattern, for example user:*",
            isOptional: optional
        )
    }

    static func keyword(
        _ name: String,
        values: [String],
        optional: Bool = true
    ) -> Self {
        .init(
            name: name,
            kind: .keyword(values),
            descriptionZH: "可选关键字：\(values.joined(separator: " / "))",
            descriptionEN: "Optional keyword: \(values.joined(separator: " / "))",
            isOptional: optional
        )
    }

    static func other(
        _ name: String,
        descriptionZH: String,
        descriptionEN: String,
        optional: Bool = false
    ) -> Self {
        .init(
            name: name,
            kind: .other,
            descriptionZH: descriptionZH,
            descriptionEN: descriptionEN,
            isOptional: optional
        )
    }
}
