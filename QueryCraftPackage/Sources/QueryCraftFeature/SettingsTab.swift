enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case license
    case appearance
    case editor
    case query
    case data
    case plugins

    var id: Self { self }

    static var visibleCases: [Self] {
        allCases.filter { $0 != .license }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .license:
            "key"
        case .appearance:
            "paintbrush"
        case .editor:
            "text.cursor"
        case .query:
            "play.circle"
        case .data:
            "tablecells"
        case .plugins:
            "puzzlepiece.extension"
        }
    }
}
