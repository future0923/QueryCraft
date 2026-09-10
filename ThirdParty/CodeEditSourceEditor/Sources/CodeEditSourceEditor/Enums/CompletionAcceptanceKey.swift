public enum CompletionAcceptanceKey: Equatable, Hashable {
    case returnKey
    case tab
    case returnOrTab

    func accepts(keyCode: UInt16) -> Bool {
        switch self {
        case .returnKey:
            keyCode == 36
        case .tab:
            keyCode == 48
        case .returnOrTab:
            keyCode == 36 || keyCode == 48
        }
    }
}
