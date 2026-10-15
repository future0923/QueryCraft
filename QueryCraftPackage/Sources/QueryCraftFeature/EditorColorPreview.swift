import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

enum EditorColorPreviewKind: String, CaseIterable, Identifiable {
    case mysql, postgresql, doris, json, elasticsearch
    var id: Self { self }
    var title: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .doris: "Doris"
        case .json: "JSON"
        case .elasticsearch: "Elasticsearch"
        }
    }
    var language: CodeLanguage { self == .json || self == .elasticsearch ? .json : .sql }
    var sqlContext: SQLHighlightContext {
        .init(databaseType: self == .postgresql ? .postgresql : self == .doris ? .doris : .mysql)
    }
    var source: String {
        switch self {
        case .mysql:
            """
            -- MySQL · click a token
            ALTER TABLE users ADD INDEX idx_active (id, active);
            SELECT u.id, COUNT(*) AS total,
                   'Hello' AS greeting
            FROM users AS u
            WHERE u.active = TRUE
              AND u.id > ?
              AND u.name IS NOT NULL;
            """
        case .postgresql:
            """
            -- PostgreSQL · quoted columns
            WITH recent AS (
              SELECT "id", payload->>'name' AS name
              FROM "public"."events"
            )
            SELECT "id", COUNT(*) OVER () AS total,
                   amount::NUMERIC, $1
            FROM recent WHERE "id" > 42;
            """
        case .doris:
            """
            -- Doris · table properties
            CREATE TABLE events (
              id BIGINT, name VARCHAR(32)
            ) DUPLICATE KEY (id)
            DISTRIBUTED BY HASH (id) BUCKETS 8
            PROPERTIES ("replication_num" = "1");
            SELECT BITMAP_COUNT(user_bitmap)
            FROM events WHERE active = TRUE;
            """
        case .json:
            #"{"name":"QueryCraft","enabled":true,"limit":1.25e+3,"optional":null,"escaped":"hello\n\u4F60","tags":["SQL","JSON"]}"#
        case .elasticsearch:
            """
            # Elasticsearch · multiple requests
            GET /events/_search?pretty=true&size=10
            {"query":{"match_all":{}},"size":10}

            POST /_bulk
            {"index":{"_index":"events"}}
            {"name":"中文😀","enabled":true}
            """
        }
    }
}

@MainActor
final class EditorPreviewHighlighter: HighlightProviding {
    private let provider: any HighlightProviding
    private var revision: UInt64 = 0
    private(set) var highlights: [HighlightRange] = []
    init(kind: EditorColorPreviewKind) {
        switch kind {
        case .json: provider = TreeSitterClient()
        case .elasticsearch: provider = WorkspaceElasticsearchJSONBodyHighlighter()
        default: provider = WorkspaceSQLLanguageService(context: kind.sqlContext)
        }
    }
    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        revision &+= 1
        highlights = []
        provider.setUp(textView: textView, codeLanguage: codeLanguage)
    }
    func willApplyEdit(textView: TextView, range: NSRange) {
        revision &+= 1
        highlights = []
        provider.willApplyEdit(textView: textView, range: range)
    }
    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor @Sendable (Result<IndexSet, Error>) -> Void) {
        highlights = []
        provider.applyEdit(textView: textView, range: range, delta: delta, completion: completion)
    }
    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor @Sendable (Result<[HighlightRange], Error>) -> Void) {
        let revision = revision
        provider.queryHighlightsFor(textView: textView, range: range) { [weak self] result in
            guard let self, self.revision == revision else {
                completion(.failure(HighlightProvidingError.operationCancelled))
                return
            }
            if case .success(let captures) = result {
                self.highlights.removeAll { NSIntersectionRange($0.range, range).length > 0 }
                self.highlights.append(contentsOf: captures)
            }
            completion(result)
        }
    }
    func role(at offset: Int) -> EditorColorRole {
        Self.role(for: highlights.first { NSLocationInRange(offset, $0.range) }?.capture)
    }
    static func role(for capture: CaptureName?) -> EditorColorRole {
        switch capture {
        case .keyword: .keyword
        case .type: .object
        case .typeBuiltin: .type
        case .property: .property
        case .function, .method: .function
        case .string: .string
        case .number, .float: .number
        case .boolean: .boolean
        case .variable: .variable
        case .parameter: .parameter
        case .typeAlternate: .attribute
        case .operator: .operator
        case .punctuation: .punctuation
        case .comment: .comment
        default: .text
        }
    }
}

struct EditorColorPreview: View {
    let settings: EditorColorSettings
    let mode: EditorColorMode
    let kind: EditorColorPreviewKind
    let selectRole: (EditorColorRole) -> Void
    private let language: ApplicationLanguage
    private var copy: AppCopy { AppCopy(language: language) }
    @State private var source: String
    @State private var state = SourceEditorState()
    @State private var highlighter: EditorPreviewHighlighter
    @State private var search = false

    init(settings: EditorColorSettings, mode: EditorColorMode, kind: EditorColorPreviewKind,
         language: ApplicationLanguage = .activeInterfaceLanguage,
         selectRole: @escaping (EditorColorRole) -> Void) {
        self.settings = settings; self.mode = mode; self.kind = kind; self.selectRole = selectRole
        self.language = language
        _source = State(initialValue: kind.source)
        _highlighter = State(initialValue: EditorPreviewHighlighter(kind: kind))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(copy.text("搜索示例", "Search Sample"), isOn: $search).toggleStyle(.checkbox)
                    .onChange(of: search) { _, value in state.findText = value ? "name" : ""; state.findPanelVisible = value }
                Spacer()
                Button(copy.text("重置示例", "Reset Sample")) { source = kind.source }
                    .buttonStyle(.borderless)
            }.font(.caption).padding(8)
            SourceEditor($source, language: kind.language,
                         configuration: .init(appearance: .init(
                            theme: WorkspaceEditorTheme.make(for: mode.appearanceName, settings: settings),
                            font: .monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: true),
                            peripherals: .init(showGutter: true, showMinimap: false, showFoldingRibbon: false)),
                         state: $state, highlightProviders: [highlighter])
                .onChange(of: state.cursorPositions) { _, positions in
                    if let position = positions?.first?.range.location, position != NSNotFound {
                        selectRole(highlighter.role(at: position))
                    }
                }
                .accessibilityLabel(copy.text("可编辑语法配色预览", "Editable Syntax Color Preview"))
        }
    }
}
