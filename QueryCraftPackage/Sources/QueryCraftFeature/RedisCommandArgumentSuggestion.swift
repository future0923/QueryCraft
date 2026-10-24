#if os(iOS)
import QueryCraftMobileCore
#endif
struct RedisCommandArgumentSuggestion: Identifiable, Equatable, Sendable {
    let value: String
    let detail: String

    var id: String { value }
}
