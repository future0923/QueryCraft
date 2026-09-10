import SwiftUI

enum RedisValueDisplayFormat: CaseIterable, Identifiable, Sendable {
    case text
    case json
    case hex

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .text:
            AppCopy.current.text("文本", "Text")
        case .json:
            "JSON"
        case .hex:
            "Hex"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .json: "curlybraces"
        case .hex: "number"
        }
    }
}
