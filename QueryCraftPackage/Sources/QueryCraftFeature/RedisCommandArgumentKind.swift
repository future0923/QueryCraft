enum RedisCommandArgumentKind: Equatable, Sendable {
    case key
    case field
    case value
    case integer
    case cursor
    case pattern
    case keyword([String])
    case other
}
