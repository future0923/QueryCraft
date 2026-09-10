enum RedisKeyExpirationMode: String, CaseIterable, Identifiable {
    case persistent
    case expires

    var id: Self { self }

    var title: String {
        switch self {
        case .persistent:
            AppCopy.current.text("永不过期", "Persistent")
        case .expires:
            AppCopy.current.text("设置过期", "Set Expiry")
        }
    }
}
