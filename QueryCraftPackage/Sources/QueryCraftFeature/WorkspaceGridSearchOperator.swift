enum WorkspaceGridSearchOperator: String, CaseIterable, Identifiable, Sendable {
    case contains
    case equals
    case beginsWith
    case endsWith

    var id: Self { self }

    var title: String {
        switch self {
        case .contains:
            AppCopy.current.text("包含", "Contains")
        case .equals:
            AppCopy.current.text("等于", "Equals")
        case .beginsWith:
            AppCopy.current.text("开头是", "Begins With")
        case .endsWith:
            AppCopy.current.text("结尾是", "Ends With")
        }
    }
}
