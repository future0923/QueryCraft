// Shared desktop/mobile complete-value editing budget. Never write a preview chunk as a whole value.
enum RedisStringEditingLimit {
    static let maximumBytes = 100 * 1_024 * 1_024
}
