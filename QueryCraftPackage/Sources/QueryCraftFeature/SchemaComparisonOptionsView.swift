import SwiftUI

/// System sidebar, grouped forms and standard controls. Glass belongs to the
/// navigation/action layer; the settings themselves use the system content surface.
struct SchemaComparisonOptionsView: View {
    @State private var options: SchemaComparisonOptions
    @State private var pane = Pane.objects
    let apply: (SchemaComparisonOptions) -> Void
    let cancel: () -> Void
    private var copy: AppCopy { .current }
    private enum Pane: String, CaseIterable, Identifiable {
        case objects, comparison, filters, advanced
        var id: Self { self }
        var title: String {
            switch self {
            case .objects: AppCopy.current.text("比较对象", "Objects")
            case .comparison: AppCopy.current.text("比较规则", "Comparison")
            case .filters: AppCopy.current.text("表名筛选", "Table Filters")
            case .advanced: AppCopy.current.text("高级选项", "Advanced")
            }
        }
        var symbol: String {
            switch self { case .objects: "square.stack.3d.up"; case .comparison: "slider.horizontal.3"; case .filters: "line.3.horizontal.decrease"; case .advanced: "gearshape" }
        }
    }
    init(options: SchemaComparisonOptions, apply: @escaping (SchemaComparisonOptions) -> Void, cancel: @escaping () -> Void) {
        _options = State(initialValue: options)
        self.apply = apply; self.cancel = cancel
    }
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(Pane.allCases, selection: $pane) { pane in Label(pane.title, systemImage: pane.symbol).tag(pane) }
                    .listStyle(.sidebar).navigationSplitViewColumnWidth(180)
                    .accessibilityIdentifier("schemaComparisonOptionsNavigation")
            } detail: {
                Form {
                    switch pane {
                    case .objects: objects
                    case .comparison: comparison
                    case .filters: filters
                    case .advanced: advanced
                    }
                }.formStyle(.grouped).toggleStyle(.checkbox).navigationTitle(pane.title)
            }.navigationSplitViewStyle(.balanced)
            Divider()
            HStack {
                Text(options.validationMessage ?? "").font(.caption).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copy.text("取消", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(copy.text("完成", "Done")) { apply(options) }.keyboardShortcut(.defaultAction)
                    .disabled(!options.hasScope || options.validationMessage != nil)
                    .modifier(SchemaComparisonPrimaryActionStyle())
                    .accessibilityIdentifier("schemaComparisonOptionsDone")
            }.modifier(SchemaComparisonFooterStyle())
        }.frame(width: 780, height: 610).modifier(SchemaComparisonActionBarStyle())
    }
    @ViewBuilder private var objects: some View {
        Section(copy.text("表与约束", "Tables and Constraints")) {
            option("比较表", "Compare tables", \.tables)
            Group {
                option("比较主键", "Primary keys", \.primaryKeys)
                option("比较外键", "Foreign keys", \.foreignKeys)
                option("比较唯一键", "Unique keys", \.uniqueKeys)
                option("比较索引", "Indexes", \.indexes)
                option("比较触发器", "Triggers", \.triggers)
            }.disabled(!options.tables)
            option("比较检查约束", "Check constraints", \.checks).disabled(!options.tables)
            Toggle(copy.text("比较排除约束", "Exclusion constraints"), isOn: .constant(false)).disabled(true)
                .help(copy.text("MySQL 不支持排除约束。", "MySQL does not support exclusion constraints."))
        }
        Section(copy.text("其他对象", "Other Objects")) {
            option("比较视图", "Views", \.views)
            option("比较函数与存储过程", "Functions and procedures", \.functions)
            Toggle(copy.text("比较序列", "Sequences"), isOn: .constant(false)).disabled(true)
            Toggle(copy.text("比较规则", "Rules"), isOn: .constant(false)).disabled(true)
            Toggle(copy.text("比较所有者", "Owners"), isOn: .constant(false)).disabled(true)
            Text(copy.text("序列、规则、所有者与排除约束属于 PostgreSQL 的对象能力，MySQL 不适用。", "Sequences, rules, owners and exclusion constraints are PostgreSQL object capabilities and do not apply to MySQL."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var comparison: some View {
        Section(copy.text("差异规则", "Difference Rules")) {
            option("忽略注释差异", "Ignore comments", \.ignoresComments)
            option("比较字符集与排序规则", "Compare character sets and collations", \.compareCharset)
            option("比较字段顺序", "Compare column order", \.compareColumnOrder)
            option("忽略表名大小写", "Ignore table name case", \.ignoreTableNameCase)
            option("忽略字段名大小写", "Ignore column name case", \.ignoreColumnNameCase)
        }
        Section(copy.text("重命名检测", "Rename Detection")) {
            option("检测字段重命名", "Detect column renames", \.detectRenames)
            option("检测表重命名", "Detect table renames", \.detectTableRenames).disabled(!options.detectRenames)
            threshold(copy.text("重命名相似度", "Rename similarity"), value: $options.renameThreshold,
                      identifier: "schemaComparisonRenameThreshold")
                .disabled(!options.detectRenames)
            Text(options.detectRenames
                 ? copy.text("相似度达到此值时识别为重命名，数值越高越严格。请在差异和 SQL 中核对结果。", "A similarity score at or above this value identifies a rename. Higher values are stricter. Review the differences and SQL.")
                 : copy.text("先开启「检测字段重命名」才能调整相似度；数值越高，识别越严格。", "Enable Detect column renames to adjust similarity. Higher values are stricter."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var filters: some View {
        Section(copy.text("表名过滤", "Table Name Filters")) {
            Picker(copy.text("匹配方式", "Syntax"), selection: $options.filterSyntax) {
                Text(copy.text("正则表达式", "Regular Expression")).tag(SchemaComparisonOptions.FilterSyntax.regularExpression)
                Text(copy.text("通配符（兼容旧配置）", "Wildcard (Legacy Configurations)")).tag(SchemaComparisonOptions.FilterSyntax.wildcard)
            }
            TextField(copy.text("只比较匹配的表", "Include matching tables"), text: $options.includedTables, prompt: Text("^user_"))
                .accessibilityIdentifier("schemaComparisonIncludedTables")
            TextField(copy.text("跳过匹配的表", "Exclude matching tables"), text: $options.excludedTables, prompt: Text("_bak$"))
            Picker(copy.text("同时匹配时", "When both match"), selection: $options.filterPriority) {
                Text(copy.text("排除优先", "Exclude Wins")).tag(SchemaComparisonOptions.FilterPriority.exclude)
                Text(copy.text("包含优先", "Include Wins")).tag(SchemaComparisonOptions.FilterPriority.include)
            }
            Text(copy.text("包含为空时匹配全部表。排除可用逗号分隔多个正则；括号、字符类与量词内的逗号会保留。", "An empty include filter matches every table. Separate exclude expressions with commas; commas inside groups, character classes and quantifiers are retained."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(copy.text("批次模式", "Batch Patterns")) {
            TextField(copy.text("表名模式", "Table patterns"), text: $options.batchPatterns, prompt: Text("orders_*, events_*"))
            Text(copy.text("多个模式用逗号分隔，在依赖关系中按表名归组；不改变比较范围。", "Comma-separated patterns group table names in Dependencies; they do not change the comparison scope."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var advanced: some View {
        Section(copy.text("SQL 计划", "SQL Plan")) {
            Toggle(copy.text("使用级联删除", "Use cascading deletion"), isOn: .constant(false)).disabled(true)
                .help(copy.text("MySQL 的 DROP TABLE 不支持 CASCADE；引用关系在依赖计划中处理。", "MySQL DROP TABLE does not support CASCADE; references are handled in the dependency plan."))
            option("生成回退脚本", "Generate rollback script", \.enableRollback)
            Text(copy.text("回退脚本恢复结构，无法恢复被删除或截断的数据。缺少原始定义时会标明回退不完整。", "Rollback scripts restore structure, not deleted or truncated data. Missing original definitions are reported as incomplete rollback."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(copy.text("数据库方言", "Database Dialects")) {
            dialect(copy.text("源数据库方言", "Source dialect"), selection: $options.sourceDialect)
            dialect(copy.text("目标数据库方言", "Target dialect"), selection: $options.targetDialect)
            threshold(copy.text("类型兼容性警告阈值", "Type compatibility warning threshold"), value: $options.compatibilityThreshold,
                      identifier: "schemaComparisonCompatibilityThreshold")
            Text(copy.text("类型兼容性评分低于此值时提示警告。数值越高，提醒越多；不影响比较结果或 SQL 生成。", "Warn when the type compatibility score falls below this value. Higher values produce more warnings; comparison results and SQL generation are unaffected."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func threshold(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        // A continuous native slider avoids the dense tick marks produced by
        // step: 0.01. Round the binding to retain the same stored precision.
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value.wrappedValue }, set: {
                    value.wrappedValue = ($0 * 100).rounded() / 100
                }), in: 0...1)
                    .frame(minWidth: 140, maxWidth: 230)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
        }
    }
    private func option(_ zh: String, _ en: String, _ key: WritableKeyPath<SchemaComparisonOptions, Bool>) -> some View {
        Toggle(copy.text(zh, en), isOn: Binding(get: { options[keyPath: key] }, set: { options[keyPath: key] = $0 }))
    }
    private func dialect(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(copy.text("自动", "Automatic")).tag("")
            Text("MySQL").tag("mysql")

        }
    }
}
