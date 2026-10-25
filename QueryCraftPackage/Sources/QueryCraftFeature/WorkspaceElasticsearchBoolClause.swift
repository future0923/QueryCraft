public enum WorkspaceElasticsearchBoolClause: String, Codable, CaseIterable, Hashable, Sendable {
    case filter
    case must
    case should
    case mustNot = "must_not"
}
