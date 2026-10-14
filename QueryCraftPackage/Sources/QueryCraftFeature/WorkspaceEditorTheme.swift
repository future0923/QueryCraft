import AppKit
import CodeEditSourceEditor

enum WorkspaceEditorTheme {
    static func make(
        for appearanceName: NSAppearance.Name,
        settings: EditorColorSettings = .init()
    ) -> EditorTheme {
        let appearance = NSAppearance(named: appearanceName) ?? NSAppearance(named: .aqua)!
        let mode: EditorColorMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let palette = settings[mode]
        func color(_ role: EditorColorRole) -> NSColor {
            EditorHexColor.color(palette.hex(for: role, mode: mode))
        }
        func attribute(_ role: EditorColorRole) -> EditorTheme.Attribute {
            .init(color: color(role), bold: role == .keyword && palette.boldKeywords,
                  italic: role == .comment && palette.italicComments)
        }
        var theme = EditorTheme(
            text: attribute(.text), insertionPoint: color(.cursor),
            invisibles: attribute(.comment), background: color(.background),
            lineHighlight: color(.currentLine),
            // Syntax foregrounds remain visible inside selection; keep its fill translucent.
            selection: color(.selection).withAlphaComponent(mode == .dark ? 0.35 : 0.22),
            keywords: attribute(.keyword), commands: attribute(.function),
            types: attribute(.type), attributes: attribute(.attribute),
            variables: attribute(.variable), values: attribute(.boolean),
            numbers: attribute(.number), strings: attribute(.string),
            characters: attribute(.string), comments: attribute(.comment)
        )
        theme.captureOverrides = [
            .type: attribute(.object), .typeBuiltin: attribute(.type),
            .property: attribute(.property), .function: attribute(.function),
            .method: attribute(.function), .parameter: attribute(.parameter),
            .boolean: attribute(.boolean), .operator: attribute(.operator),
            .punctuation: attribute(.punctuation)
        ]
        theme.lineNumber = color(.lineNumber)
        theme.currentLineNumber = color(.currentLineNumber)
        theme.searchMatch = color(.searchMatch)
        theme.searchCurrent = color(.searchCurrent)
        theme.searchText = color(.searchText)
        return theme
    }
}
