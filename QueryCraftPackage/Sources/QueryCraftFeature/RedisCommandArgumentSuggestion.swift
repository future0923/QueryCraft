struct RedisCommandArgumentSuggestion: Identifiable, Equatable, Sendable {
    let value: String
    let detail: String

    var id: String { value }
}
