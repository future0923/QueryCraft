import AppKit
import CodeEditSourceEditor
import SwiftUI

struct WorkspaceCodeEditQueryEditor: View {
    @Binding private var text: String
    @Binding private var selectedRange: NSRange
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorState: SourceEditorState
    @State private var preferences = ApplicationPreferences.shared
    private let languageService: WorkspaceSQLLanguageService
    private let commandCoordinator: WorkspaceQueryEditorCommandCoordinator?
    private let completionService: WorkspaceSQLCompletionService?

    init(
        text: Binding<String>,
        selectedRange: Binding<NSRange>,
        languageService: WorkspaceSQLLanguageService,
        commandCoordinator: WorkspaceQueryEditorCommandCoordinator? = nil,
        completionService: WorkspaceSQLCompletionService? = nil
    ) {
        _text = text
        _selectedRange = selectedRange
        self.languageService = languageService
        self.commandCoordinator = commandCoordinator
        self.completionService = completionService
        _editorState = State(
            initialValue: SourceEditorState(
                cursorPositions: [CursorPosition(range: selectedRange.wrappedValue)]
            )
        )
    }

    var body: some View {
        SourceEditor(
            $text,
            language: .sql,
            configuration: configuration,
            state: $editorState,
            highlightProviders: [languageService],
            coordinators: commandCoordinator.map { [$0] } ?? [],
            completionDelegate: completionService
        )
        .onChange(of: editorState.cursorPositions) { _, cursorPositions in
            guard let range = cursorPositions?.first?.range,
                  range.location != NSNotFound,
                  selectedRange != range
            else {
                return
            }
            selectedRange = range
            languageService.selectionDidChange()
        }
        .onChange(of: text) { _, text in
            commandCoordinator?.replaceEditorTextIfNeeded(text)
        }
        .accessibilityLabel(
            AppCopy.current.text("SQL 查询编辑器", "SQL query editor")
        )
        .accessibilityIdentifier("queryEditor")
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme,
                font: preferences.editorFont(),
                wrapLines: false,
                tabWidth: preferences.editorIndentationWidth
            ),
            behavior: .init(
                indentOption: preferences.editorIndentationStyle == .spaces
                    ? .spaces(count: preferences.editorIndentationWidth)
                    : .tab,
                completionAcceptanceKey:
                    preferences.editorCompletionKey.codeEditValue
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(
                    top: 8,
                    left: 0,
                    bottom: 8,
                    right: 8
                )
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }

    private var theme: EditorTheme {
        WorkspaceEditorTheme.make(
            for: colorScheme == .dark ? .darkAqua : .aqua
        )
    }
}

enum WorkspaceEditorTheme {
    static func make(for appearanceName: NSAppearance.Name) -> EditorTheme {
        let appearance = NSAppearance(named: appearanceName)
            ?? NSAppearance(named: .aqua)!
        func color(_ semanticColor: NSColor) -> NSColor {
            semanticColor.resolved(for: appearance)
        }

        return .init(
            text: .init(color: color(.textColor)),
            insertionPoint: color(.controlAccentColor),
            invisibles: .init(color: color(.tertiaryLabelColor)),
            background: color(.textBackgroundColor),
            lineHighlight: color(.tertiarySystemFill),
            selection: color(.selectedTextBackgroundColor),
            keywords: .init(color: color(.systemPurple), bold: true),
            commands: .init(color: color(.systemTeal)),
            types: .init(color: color(.systemBlue)),
            attributes: .init(color: color(.systemOrange)),
            variables: .init(color: color(.textColor)),
            values: .init(color: color(.systemBlue)),
            numbers: .init(color: color(.systemOrange)),
            strings: .init(color: color(.systemRed)),
            characters: .init(color: color(.systemRed)),
            comments: .init(color: color(.secondaryLabelColor), italic: true)
        )
    }
}
