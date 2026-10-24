#if os(iOS)
import QueryCraftMobileCore
#endif
struct RedisKeySearchRequest: Equatable, Sendable {
    let text: String
    let mode: RedisKeySearchMatchMode
}
