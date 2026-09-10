import AppKit
import CodeEditSourceEditor
import SwiftUI

struct WorkspaceCodeEditElasticsearchEditor: View {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorState: SourceEditorState
    @State private var preferences = ApplicationPreferences.shared
    @State private var bodyHighlighter =
        WorkspaceElasticsearchJSONBodyHighlighter()
    @State private var completionService: WorkspaceElasticsearchCompletionService
    @State private var navigationCoordinator = WorkspaceElasticsearchEditorNavigationCoordinator()
    private let navigationRequest: WorkspaceElasticsearchEditorNavigationRequest?

    init(
        text: Binding<String>,
        selectedRange: Binding<NSRange>,
        navigationRequest: WorkspaceElasticsearchEditorNavigationRequest? = nil,
        completionFields: @escaping @MainActor (String?) async -> [String],
        completionResources: @escaping @MainActor ()
            -> [WorkspaceElasticsearchCompletionResource]
    ) {
        _text = text
        _selectedRange = selectedRange
        self.navigationRequest = navigationRequest
        _editorState = State(initialValue: SourceEditorState(
            cursorPositions: [CursorPosition(range: selectedRange.wrappedValue)]
        ))
        _completionService = State(initialValue:
            WorkspaceElasticsearchCompletionService(
                fields: completionFields,
                resources: completionResources,
                indentationUnit: {
                    let preferences = ApplicationPreferences.shared
                    if preferences.editorIndentationStyle == .tabs {
                        return "\t"
                    }
                    return String(
                        repeating: " ",
                        count: preferences.editorIndentationWidth
                    )
                }
            )
        )
    }

    var body: some View {
        SourceEditor(
            $text,
            language: .default,
            configuration: configuration,
            state: $editorState,
            highlightProviders: [bodyHighlighter],
            coordinators: [navigationCoordinator],
            completionDelegate: completionService
        )
        .onChange(of: editorState.cursorPositions) { _, positions in
            guard let range = positions?.first?.range,
                  range.location != NSNotFound
            else { return }
            selectedRange = range
        }
        .onChange(of: navigationRequest) { _, request in
            if let request { navigationCoordinator.navigate(to: request.range) }
        }
        .accessibilityLabel(
            AppCopy.current.text(
                "Elasticsearch 请求编辑器",
                "Elasticsearch request editor"
            )
        )
        .accessibilityIdentifier("elasticsearchRequestEditor")
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: WorkspaceEditorTheme.make(
                    for: colorScheme == .dark ? .darkAqua : .aqua
                ),
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
                contentInsets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 8)
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: true
            )
        )
    }
}
