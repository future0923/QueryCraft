import Foundation

struct WorkspaceElasticsearchAliasBinding: Equatable, Sendable {
    let indexName: String
    let aliasName: String
    var isWriteIndex: Bool?
    /// Canonical alias options excluding `is_write_index`. This retains filters,
    /// routing and future server fields when the write-index flag changes.
    let optionsJSON: Data

    var key: String { indexName + "\u{0}" + aliasName }
}

struct WorkspaceElasticsearchAliasSnapshot: Equatable, Sendable {
    let selection: WorkspaceDatabaseObjectSelection
    let bindings: [WorkspaceElasticsearchAliasBinding]
    let rawJSON: Data
}

struct WorkspaceElasticsearchAliasEditorRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let original: WorkspaceElasticsearchAliasBinding?
    var binding: WorkspaceElasticsearchAliasBinding
    var isRemoved: Bool

    var isNew: Bool { original == nil }
    var isModified: Bool { isNew || isRemoved || original != binding }
}

struct WorkspacePreparedElasticsearchAliasUpdate: Equatable, Sendable {
    let baseline: WorkspaceElasticsearchAliasSnapshot
    let desiredBindings: [WorkspaceElasticsearchAliasBinding]
    let request: WorkspaceRequest
}

enum WorkspaceElasticsearchAliasError: LocalizedError {
    case unsupportedResource
    case invalidName
    case duplicateBinding
    case noChanges
    case conflict
    case uncertain

    var errorDescription: String? { message(copy: .current) }

    func message(copy: AppCopy) -> String {
        switch self {
        case .unsupportedResource:
            copy.text("只有普通索引和 Alias 支持管理绑定。", "Only ordinary indices and aliases support binding management.")
        case .invalidName:
            copy.text("请输入有效的小写 Alias 或索引名称。", "Enter a valid lowercase alias or index name.")
        case .duplicateBinding:
            copy.text("这个 Alias 与索引的绑定已经存在。", "This alias and index binding already exists.")
        case .noChanges:
            copy.text("没有可提交的 Alias 更改。", "There are no alias changes to commit.")
        case .conflict:
            copy.text("Alias 绑定已被外部修改。草稿已保留，请放弃并刷新后重新核对。", "Alias bindings changed externally. Your draft is retained; discard and refresh to review the server state.")
        case .uncertain:
            copy.text("无法确认 Alias 更改是否生效。草稿已保留，禁止直接重试；请放弃并刷新核对。", "The alias update could not be confirmed. Your draft is retained and retry is blocked; discard and refresh to verify it.")
        }
    }
}

struct WorkspaceElasticsearchAliasNotSentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
