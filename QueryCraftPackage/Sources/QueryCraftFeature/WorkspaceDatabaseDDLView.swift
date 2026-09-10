import CodeEditSourceEditor
import SwiftUI

struct WorkspaceDatabaseDDLView: View {
    let ddl: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var editorState = SourceEditorState()
    @State private var languageService = WorkspaceSQLLanguageService()
    @State private var preferences = ApplicationPreferences.shared

    var body: some View {
        SourceEditor(
            .constant(ddl),
            language: .sql,
            configuration: configuration,
            state: $editorState,
            highlightProviders: [languageService]
        )
        .id(ddl)
        .accessibilityLabel(
            AppCopy.current.text("DDL SQL 代码", "DDL SQL code")
        )
        .accessibilityIdentifier("databaseObjectDDL")
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: WorkspaceEditorTheme.make(
                    for: colorScheme == .dark ? .darkAqua : .aqua
                ),
                font: preferences.editorFont(),
                wrapLines: false,
                tabWidth: preferences.editorIndentationWidth,
                bracketPairEmphasis: nil
            ),
            behavior: .init(
                isEditable: false,
                isSelectable: true,
                indentOption: preferences.editorIndentationStyle == .spaces
                    ? .spaces(count: preferences.editorIndentationWidth)
                    : .tab
            ),
            layout: .init(
                additionalTextInsets: NSEdgeInsets(
                    top: 8,
                    left: 0,
                    bottom: 8,
                    right: 0
                )
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }
}
