enum TableEmptyStringDisplayStyle: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case empty

    var id: Self { self }

    var displayText: String {
        switch self {
        case .uppercase:
            "EMPTY"
        case .lowercase:
            "empty"
        case .empty:
            ""
        }
    }
}
