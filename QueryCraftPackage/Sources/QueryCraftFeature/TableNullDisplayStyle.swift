enum TableNullDisplayStyle: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case empty

    var id: Self { self }

    var displayText: String {
        switch self {
        case .uppercase:
            "NULL"
        case .lowercase:
            "null"
        case .empty:
            ""
        }
    }
}
