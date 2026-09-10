enum WorkspaceContentTabAction {
    case close(WorkspaceContentTabID)
    case closeOthers(WorkspaceContentTabID)
    case closeToRight(WorkspaceContentTabID)
    case closeAll
}
