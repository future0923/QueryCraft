enum WorkspaceSidebarMode:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Sendable
{
    case items
    case queries

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .items:
            AppCopy.current.text("项目", "Items")
        case .queries:
            AppCopy.current.text("查询", "Queries")
        }
    }
}
