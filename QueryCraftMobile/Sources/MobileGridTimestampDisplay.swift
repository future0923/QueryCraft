import QueryCraftMobileCore

/// Platform presentation state only. Parsing, type/name hints, time-zone handling,
/// caching and preview bounds all come from the actual Mac formatter.
@MainActor final class MobileGridTimestampDisplay {
    private var scope = ""
    private var columns: [WorkspaceDatabaseDataColumn] = []
    private var modes: [Int: WorkspaceTimestampDisplayMode] = [:]

    @discardableResult
    func configure(scope: String, columns: [WorkspaceDatabaseDataColumn]) -> Bool {
        guard self.scope != scope || self.columns != columns else { return false }
        self.scope = scope; self.columns = columns
        modes.removeAll()
        return true
    }

    func mode(column: Int) -> WorkspaceTimestampDisplayMode { modes[column] ?? .automatic }

    @discardableResult
    func set(_ mode: WorkspaceTimestampDisplayMode, column: Int) -> Bool {
        guard columns.indices.contains(column) else { return false }
        modes[column] = mode == .automatic ? nil : mode
        return true
    }

    func preview(_ cell: WorkspaceDatabaseDataCell, column: Int, maximumCharacterCount: Int, style: MobileGridStyle? = nil) -> String {
        let mode = mode(column: column)
        return WorkspaceTimestampDisplayFormatter.shared.preview(cell,
            column: columns.indices.contains(column) ? columns[column] : nil,
            mode: mode == .automatic && style?.formatsTimestamps == false ? .raw : mode,
            nullDisplayText: style?.nullText ?? "NULL", emptyStringDisplayText: style?.emptyText ?? "",
            maximumCharacterCount: maximumCharacterCount)
    }
}
