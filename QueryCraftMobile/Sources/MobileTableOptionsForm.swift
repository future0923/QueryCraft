import SwiftUI
import QueryCraftMobileCore

struct MobileTableOptionsForm: View {
    @Binding var options: WorkspaceDatabaseTableOptions
    let choices: WorkspaceDatabaseSchemaChoices
    var allowsDatabaseDefaults = true
    private var defaults: [String] { allowsDatabaseDefaults ? [""] : [] }
    var body: some View {
        Section(allowsDatabaseDefaults ? "常用选项 · 留空使用数据库默认值" : "常用选项") {
            MobileSchemaTextField(title: "引擎", text: $options.engine, suggestions: defaults + choices.engines)
            MobileSchemaTextField(title: "字符集", text: Binding(get: { options.characterSet }, set: { options.applyCharacterSet($0, choices: choices) }), suggestions: defaults + choices.characterSets)
            MobileSchemaTextField(title: "排序规则", text: Binding(get: { options.collation }, set: { options.applyCollation($0, choices: choices) }), suggestions: defaults + choices.collations.filter { options.characterSet.isEmpty || $0.characterSet == options.characterSet }.map(\.name))
            MobileSchemaTextField(title: "行格式", text: $options.rowFormat, suggestions: defaults + ["DYNAMIC", "COMPACT", "COMPRESSED", "REDUNDANT", "FIXED"])
            MobileSchemaTextField(title: allowsDatabaseDefaults ? "自增初始值" : "下一个自增值", text: $options.autoIncrement)
            MobileSchemaTextField(title: "表注释", text: $options.comment)
        }
        Section("高级选项") {
            MobileSchemaTextField(title: "平均行长度", text: $options.averageRowLength)
            MobileSchemaTextField(title: "最小行数", text: $options.minimumRows)
            MobileSchemaTextField(title: "最大行数", text: $options.maximumRows)
            MobileSchemaTextField(title: "键块大小", text: $options.keyBlockSize)
        }
    }
}
