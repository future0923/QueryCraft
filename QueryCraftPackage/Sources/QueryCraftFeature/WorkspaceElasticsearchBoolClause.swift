public enum WorkspaceElasticsearchBoolClause: String, CaseIterable, Hashable, Sendable {
    case filter
    case must
    case should
    case mustNot = "must_not"
}
