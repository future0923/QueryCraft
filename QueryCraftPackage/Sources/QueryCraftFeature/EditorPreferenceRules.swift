import Foundation

enum EditorPreferenceRules {
    static let indentationWidths = [2, 4, 6, 8]
    static func indentationUnit(style: EditorIndentationStyle, width: Int) -> String {
        style == .tabs ? "\t" : String(repeating: " ", count: indentationWidths.contains(width) ? width : 4)
    }
    static func acceptsReturn(_ key: EditorCompletionKey) -> Bool { key != .tab }
    static func acceptsTab(_ key: EditorCompletionKey) -> Bool { key != .returnKey }
}


enum EditorPreferenceKey {
    static let colors = "preferences.editor.colors.v1"
    static let themes = "preferences.editor.themes.v1"
    static let ansiQuoteConnections = "preferences.editor.ansiQuoteConnections.v1"
    static let fontFamily = "preferences.editor.fontFamily"
    static let fontSize = "preferences.editor.fontSize"
    static let indentationStyle = "preferences.editor.indentationStyle"
    static let indentationWidth = "preferences.editor.indentationWidth"
    static let completionKey = "preferences.editor.completionKey"
    static let keywordCase = "preferences.editor.sqlKeywordCase"
}
