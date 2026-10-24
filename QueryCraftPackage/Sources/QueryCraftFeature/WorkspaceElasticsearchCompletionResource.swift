#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

struct WorkspaceElasticsearchCompletionResource: Equatable, Sendable {
    let name: String
    let kind: WorkspaceDatabaseObjectKind
}
