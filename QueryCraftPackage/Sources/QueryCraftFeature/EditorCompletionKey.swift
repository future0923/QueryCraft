#if !os(iOS)
import CodeEditSourceEditor
#endif

enum EditorCompletionKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case returnKey
    case tab
    case returnOrTab

    var id: Self { self }

    #if !os(iOS)
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
    #endif
}
