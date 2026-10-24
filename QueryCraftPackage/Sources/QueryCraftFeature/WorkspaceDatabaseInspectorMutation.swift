#if os(iOS)
import QueryCraftMobileCore
#endif
enum WorkspaceDatabaseInspectorMutation: Equatable, Sendable {
    case value(String)
    case null
    case useDefault
}
