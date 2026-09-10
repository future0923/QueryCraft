enum RedisKeyLoadScope: Equatable, Sendable {
    case nextPage
    case matchingPage
    case allRemaining
}
