import CodeEditSourceEditor

enum EditorCompletionKey: String, CaseIterable, Identifiable {
    case returnKey
    case tab
    case returnOrTab

    var id: Self { self }

    var codeEditValue: CompletionAcceptanceKey {
        switch self {
        case .returnKey:
            .returnKey
        case .tab:
            .tab
        case .returnOrTab:
            .returnOrTab
        }
    }
}
