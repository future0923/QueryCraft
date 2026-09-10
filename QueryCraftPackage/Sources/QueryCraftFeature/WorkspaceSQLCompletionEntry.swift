import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

struct WorkspaceSQLCompletionEntry: CodeSuggestionEntry {
    let item: SQLCompletionItem

    init(_ item: SQLCompletionItem) {
        self.item = item
    }

    var label: String { item.label }
    var completionIdentity: String {
        "\(item.kind):\(item.insertionText.lowercased())"
    }
    var detail: String? { item.detail }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var deprecated: Bool { false }

    var image: Image {
        let systemName = switch item.kind {
        case .keyword: "chevron.left.forwardslash.chevron.right"
        case .function: "function"
        case .database: "cylinder"
        case .table: "tablecells"
        case .view: "eye"
        case .column: "rectangle.grid.1x2"
        case .queryOutput: "v.square"
        }
        return Image(systemName: systemName)
    }

    var imageColor: Color {
        switch item.kind {
        case .keyword: .purple
        case .function: .teal
        case .database: .blue
        case .table, .view: .orange
        case .column: .indigo
        case .queryOutput: .orange
        }
    }
}
