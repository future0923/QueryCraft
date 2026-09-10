struct RedisKeySearchRequest: Equatable, Sendable {
    let text: String
    let mode: RedisKeySearchMatchMode
}
