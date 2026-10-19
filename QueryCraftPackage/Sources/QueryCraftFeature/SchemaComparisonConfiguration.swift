import Foundation

struct SchemaComparisonOptions: Codable, Equatable, Sendable {
    var ignoresComments = false
    var selectedTables: [String]? = nil
    var includedTables = ""
    var excludedTables = ""
    var columns = true
    var indexes = true
    var constraints = true
    var tableOptions = true
    var tables = true
    var primaryKeys = true
    var foreignKeys = true
    var uniqueKeys = true
    var checks = true
    var exclusions = true
    var views = true
    var functions = true
    var sequences = true
    var triggers = true
    var rules = true
    var owners = true
    var cascadeDelete = false
    var sequenceLastValues = true
    var compareColumnOrder = false
    var compareCharset = true
    var ignoreTableNameCase = false
    var ignoreColumnNameCase = false
    var detectRenames = false
    var detectTableRenames = false
    var enableRollback = false
    var renameThreshold = 0.5
    var compatibilityThreshold = 0.5
    var sourceDialect = ""
    var targetDialect = ""
    var batchPatterns = ""
    var filterPriority = FilterPriority.exclude
    var filterSyntax = FilterSyntax.regularExpression

    enum FilterPriority: String, Codable, CaseIterable { case exclude, include }
    enum FilterSyntax: String, Codable, CaseIterable { case regularExpression, wildcard }
    var hasScope: Bool { (tables || views) && selectedTables != [] || functions }
    var validationMessage: String? {
        guard (0...1).contains(renameThreshold), (0...1).contains(compatibilityThreshold) else {
            return AppCopy.current.text("阈值必须在 0 到 1 之间。", "Thresholds must be between 0 and 1.")
        }
        guard ["", "mysql"].contains(sourceDialect), ["", "mysql"].contains(targetDialect) else {
            return AppCopy.current.text("当前连接使用 MySQL 方言，请选择自动或 MySQL。", "These connections use the MySQL dialect. Choose Automatic or MySQL.")
        }
        guard filterSyntax == .regularExpression else { return nil }
        do {
            if !includedTables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try NSRegularExpression(pattern: includedTables)
            }
            for pattern in Self.excludePatterns(excludedTables) { _ = try NSRegularExpression(pattern: pattern) }
            return nil
        } catch { return AppCopy.current.text("表名正则表达式无效：", "Invalid table-name regular expression: ") + error.localizedDescription }
    }


    func includes(_ table: String, caseInsensitive: Bool) -> Bool {
        func patterns(_ text: String) -> [String] {
            text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func matches(_ pattern: String) -> Bool {
            let expression = "^" + pattern.map { c in
                c == "*" ? ".*" : c == "?" ? "." : NSRegularExpression.escapedPattern(for: String(c))
            }.joined() + "$"
            return table.range(of: expression, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]) != nil
        }
        if let selectedTables, !selectedTables.contains(where: {
            caseInsensitive || ignoreTableNameCase ? $0.caseInsensitiveCompare(table) == .orderedSame : $0 == table
        }) { return false }
        let includeMatches: Bool
        let excludeMatches: Bool
        let hasInclude = !includedTables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasExclude = !excludedTables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filterSyntax == .regularExpression {
            guard validationMessage == nil else { return false }
            func regexMatches(_ pattern: String) -> Bool {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                return regex.firstMatch(in: table, range: NSRange(table.startIndex..., in: table)) != nil
            }
            includeMatches = !hasInclude || regexMatches(includedTables)
            excludeMatches = Self.excludePatterns(excludedTables).contains(where: regexMatches)
        } else {
            includeMatches = !hasInclude || patterns(includedTables).contains(where: matches)
            excludeMatches = patterns(excludedTables).contains(where: matches)
        }
        if hasInclude && hasExclude && includeMatches && excludeMatches { return filterPriority == .include }
        return includeMatches && !excludeMatches
    }

    static func excludePatterns(_ input: String) -> [String] {
        var output: [String] = [], current = ""
        var escaped = false, inClass = false, groups = 0, braces = 0
        for char in input {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { current.append(char); escaped = true; continue }
            if inClass { current.append(char); if char == "]" { inClass = false }; continue }
            if char == "[" { inClass = true }
            else if char == "(" { groups += 1 }
            else if char == ")" { groups = max(0, groups - 1) }
            else if char == "{" { braces += 1 }
            else if char == "}" { braces = max(0, braces - 1) }
            else if char == "," && groups == 0 && braces == 0 {
                let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { output.append(value) }
                current = ""; continue
            }
            current.append(char)
        }
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { output.append(value) }
        return output
    }

    func comparableTokens(_ tokens: [String]) -> [String] {
        var tokens = tokens
        let canonical = tokens.map(MySQLSchemaDefinition.canonicalToken)
        // Integer display width was omitted from SHOW CREATE in MySQL 8.
        // ZEROFILL still makes the display width meaningful; preserve it then.
        if canonical.count >= 5, MySQLSchemaDefinition.identifierValue(tokens[0]) != nil,
           ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT"].contains(canonical[1]),
           canonical[2] == "(", canonical[3].allSatisfy(\.isNumber), canonical[4] == ")",
           !canonical.contains("ZEROFILL") {
            tokens.removeSubrange(2...4)
        }
        guard ignoresComments else { return tokens.map(MySQLSchemaDefinition.canonicalToken) }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index].uppercased() == "COMMENT" {
                let value = index + (index + 1 < tokens.count && tokens[index + 1] == "=" ? 2 : 1)
                if value < tokens.count, tokens[value].hasPrefix("'") {
                    index = value + 1
                    continue
                }
            }
            output.append(MySQLSchemaDefinition.canonicalToken(tokens[index]))
            index += 1
        }
        return output
    }
}

/// Portable configuration contains references and options, never authentication.
struct SchemaComparisonConfiguration: Codable, Equatable, Sendable {
    struct Endpoint: Codable, Equatable, Sendable {
        let profileID: UUID?
        let database: String
    }
    var formatVersion = 1
    let source: Endpoint
    let target: Endpoint
    let options: SchemaComparisonOptions
}

extension SchemaComparisonOptions {
    private enum CodingKeys: String, CodingKey {
        case ignoresComments, selectedTables, includedTables, excludedTables, columns, indexes, constraints, tableOptions, tables, primaryKeys, foreignKeys, uniqueKeys, checks, exclusions, views, functions, sequences, triggers, rules, owners, cascadeDelete, sequenceLastValues, compareColumnOrder, compareCharset, ignoreTableNameCase, ignoreColumnNameCase, detectRenames, detectTableRenames, enableRollback, renameThreshold, compatibilityThreshold, sourceDialect, targetDialect, batchPatterns, filterPriority, filterSyntax
    }
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ignoresComments = try values.decodeIfPresent(Bool.self, forKey: .ignoresComments) ?? ignoresComments
        selectedTables = try values.decodeIfPresent([String].self, forKey: .selectedTables) ?? nil
        includedTables = try values.decodeIfPresent(String.self, forKey: .includedTables) ?? includedTables
        excludedTables = try values.decodeIfPresent(String.self, forKey: .excludedTables) ?? excludedTables
        columns = try values.decodeIfPresent(Bool.self, forKey: .columns) ?? columns
        indexes = try values.decodeIfPresent(Bool.self, forKey: .indexes) ?? indexes
        constraints = try values.decodeIfPresent(Bool.self, forKey: .constraints) ?? constraints
        tableOptions = try values.decodeIfPresent(Bool.self, forKey: .tableOptions) ?? tableOptions
        tables = try values.decodeIfPresent(Bool.self, forKey: .tables) ?? tables
        primaryKeys = try values.decodeIfPresent(Bool.self, forKey: .primaryKeys) ?? primaryKeys
        foreignKeys = try values.decodeIfPresent(Bool.self, forKey: .foreignKeys) ?? foreignKeys
        uniqueKeys = try values.decodeIfPresent(Bool.self, forKey: .uniqueKeys) ?? uniqueKeys
        checks = try values.decodeIfPresent(Bool.self, forKey: .checks) ?? checks
        exclusions = try values.decodeIfPresent(Bool.self, forKey: .exclusions) ?? exclusions
        views = try values.decodeIfPresent(Bool.self, forKey: .views) ?? views
        functions = try values.decodeIfPresent(Bool.self, forKey: .functions) ?? functions
        sequences = try values.decodeIfPresent(Bool.self, forKey: .sequences) ?? sequences
        triggers = try values.decodeIfPresent(Bool.self, forKey: .triggers) ?? triggers
        rules = try values.decodeIfPresent(Bool.self, forKey: .rules) ?? rules
        owners = try values.decodeIfPresent(Bool.self, forKey: .owners) ?? owners
        cascadeDelete = try values.decodeIfPresent(Bool.self, forKey: .cascadeDelete) ?? cascadeDelete
        sequenceLastValues = try values.decodeIfPresent(Bool.self, forKey: .sequenceLastValues) ?? sequenceLastValues
        compareColumnOrder = try values.decodeIfPresent(Bool.self, forKey: .compareColumnOrder) ?? compareColumnOrder
        compareCharset = try values.decodeIfPresent(Bool.self, forKey: .compareCharset) ?? compareCharset
        ignoreTableNameCase = try values.decodeIfPresent(Bool.self, forKey: .ignoreTableNameCase) ?? ignoreTableNameCase
        ignoreColumnNameCase = try values.decodeIfPresent(Bool.self, forKey: .ignoreColumnNameCase) ?? ignoreColumnNameCase
        detectRenames = try values.decodeIfPresent(Bool.self, forKey: .detectRenames) ?? detectRenames
        detectTableRenames = try values.decodeIfPresent(Bool.self, forKey: .detectTableRenames) ?? detectTableRenames
        enableRollback = try values.decodeIfPresent(Bool.self, forKey: .enableRollback) ?? enableRollback
        renameThreshold = try values.decodeIfPresent(Double.self, forKey: .renameThreshold) ?? renameThreshold
        compatibilityThreshold = try values.decodeIfPresent(Double.self, forKey: .compatibilityThreshold) ?? compatibilityThreshold
        sourceDialect = try values.decodeIfPresent(String.self, forKey: .sourceDialect) ?? sourceDialect
        targetDialect = try values.decodeIfPresent(String.self, forKey: .targetDialect) ?? targetDialect
        batchPatterns = try values.decodeIfPresent(String.self, forKey: .batchPatterns) ?? batchPatterns
        filterPriority = try values.decodeIfPresent(FilterPriority.self, forKey: .filterPriority) ?? filterPriority
        filterSyntax = try values.decodeIfPresent(FilterSyntax.self, forKey: .filterSyntax) ?? .wildcard
    }
}
