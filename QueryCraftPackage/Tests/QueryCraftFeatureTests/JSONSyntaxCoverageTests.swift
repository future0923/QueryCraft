import AppKit
import Testing
@testable import CodeEditSourceEditor
@testable import QueryCraftFeature

@MainActor
struct JSONSyntaxCoverageTests {
    nonisolated static let jsonCorpus = [
        #"{«property|"name"»:«string|"中文😀"»,«property|"count"»:«number|-1.25e+3»,"ok":«boolean|true»,"missing":«boolean|null»}"#,
        #"{«property|"nested"»:{«property|"array"»:[«number|0»,«boolean|false»,«string|"value"»]}}"#,
        #"{"escaped":"hello«typeAlternate|\n»world«typeAlternate|\u4F60»«typeAlternate|\"»"}"#,
        #"{"«property|a»«typeAlternate|\u0062»«property|c»":"key escapes stay distinct"}"#,
        #"«punctuation|[»«number|1», «number|2.5E-4», «boolean|null»«punctuation|]»"#,
        #"{"field": {«property|"unfinished"»: «string|"value"», "next": "#,
        #"{«property|"query"»: {"#,
        "«comment|// comment: SELECT 123»\n{«property|\"valid\"»:«boolean|true»}",
        #"{"«property|emoji😀»":«string|"GET /not-a-request"»}"#,
        #"{«property|"same"»:«number|1»,«property|"same"»:«number|2»}"#,
        #"{"v":"«typeAlternate|\t»«typeAlternate|\r»«typeAlternate|\b»«typeAlternate|\f»«typeAlternate|\/»«typeAlternate|\\»"}"#,
        #"{"v":"«typeAlternate|\uD83D»«typeAlternate|\uDE00»«typeAlternate|\u0000»"}"#,
        #"[«number|-0»,«number|0.0»,«number|1e+0»,«number|1E-10»,«number|1.7976931348623157e+308»]"#,
        #"{«property|""»:«string|""»,«property|"a.b[0]"»:«boolean|false»}"#,
        #"«boolean|true»"#,
        #"«boolean|null»"#,
        #"«number|-42.5E+12»"#,
        #"«string|"root 😀 é"»"#,
        #"{"v":«string|"// not a comment # GET /users"»}"#,
        #"{«property|"items"»:[{"id":«number|1»},{"id":«number|2»}],«property|"next"»:«boolean|null»}"#,
        "{\r\n\t«property|\"a\"»: «number|1»,\r\n\t«property|\"b\"»: «boolean|false»\r\n}",
        #"{«property|"array"»: ["#,
        #"{"a":1, «property|"b"»:"#,
        #"[{},[],«boolean|true»,«boolean|false»,«boolean|null»,«number|0»]"#,
        "", " \t\r\n", "{}", "[]",
    ]

    nonisolated static let requestCorpus = [
        "«keyword|GET» «type|/users/_search»\n{«property|\"query\"»:{«property|\"match_all\"»:{}}}",
        "«keyword|POST» «type|/_bulk»\n{«property|\"index\"»:{\"_index\":«string|\"users\"»}}\n{«property|\"name\"»:«string|\"中文😀\"»}\n",
        "«keyword|GET» «type|/first/_search»\n{«property|\"size\"»:«number|10»}\n«keyword|POST» «type|/second/_search»\n{«property|\"query\"»:{\"term\":{\"active\":«boolean|true»}}}",
        "«comment|# Search users»\n«keyword|GET» «type|/users/_search»\n{«property|\"size\"»:«number|10»}",
        "GET /users/_search«punctuation|?»«parameter|pretty»«punctuation|=»«boolean|true»«punctuation|&»«parameter|size»=«number|10»&«parameter|q»=«string|hello%20world»\n{}",
        "GET /users/_search\n{«property|\"size\"»:«number|10»}\nGET /bad path\n{«property|\"query\"»: {",
        "«keyword|get» «type|/users/_search»\r\n{«property|\"name\"»:«string|\"😀\"»}",
        "GET /first/_search\n{\"unfinished\": {\nGET /second/_search\n{«property|\"size\"»:«number|10»}",
        "«keyword|HEAD» «type|/users»\n«keyword|DELETE» «type|/users/_doc/1»\n«keyword|PUT» «type|/users/_doc/2»\n{«property|\"active\"»:«boolean|false»}",
        "\t«keyword|post»\t«type|/events/_search»\n{«property|\"size\"»:«number|0»}",
        "GET /_search?«parameter|q»=«string|name%3Afoo%26bar»&«parameter|q»=«string|second»&«parameter|pretty»&«parameter|empty»=\n{}",
        "GET /_search?«parameter|x»=«number|-1.5e+2»&«parameter|y»=«boolean|false»&«parameter|z»=«boolean|null»&«parameter|timeout»=«string|10s»\n{}",
        "GET /_search\n«comment|# 中文😀 comment»\n{«property|\"query\"»:{\n«comment|// inner comment»\n«property|\"match_all\"»:{}}}",
        "POST /_msearch\n{«property|\"index\"»:«string|\"a\"»}\n{«property|\"size\"»:«number|1»}\n{«property|\"index\"»:«string|\"b\"»}\n{«property|\"size\"»:«number|2»}\n",
        "GET /_search\n{«property|\"text\"»:«string|\"POST /_bulk\"»}\n«comment|// GET /fake»\nGET /next\n{«property|\"ok\"»:«boolean|true»}",
        "GET /a\n{}\nGET /b\n{}\nGET /c\n{«property|\"last\"»:«number|3»}",
        "«keyword|GET» «type|/中文😀/_search»?«parameter|routing»=«string|用户😀»\n{«property|\"键😀\"»:«string|\"值\"»}",
        "«keyword|GET» «type|/a»\r{«property|\"one\"»:«number|1»}\r«keyword|GET» «type|/b»\r{«property|\"two\"»:«number|2»}",
        "GET /a\n{\"broken\": [\nGET /b\n{«property|\"healthy\"»:«boolean|true»}\nGET /c\n{«property|\"last\"»:«number|3»}",
        "", "\r\n", "«comment|# comment only 😀»", "«keyword|GET»", "«keyword|GET» «type|/»",
    ]

    @Test(arguments: jsonCorpus)
    func sharedJSONCoversRedisKafkaAndDocumentValues(_ marked: String) async throws {
        try await verify(marked, provider: TreeSitterClient())
    }

    @Test(arguments: requestCorpus)
    func elasticsearchCombinesRequestAndBodyColors(_ marked: String) async throws {
        try await verify(marked, provider: WorkspaceElasticsearchJSONBodyHighlighter())
    }

    @Test
    func editingRequestBoundariesRejectsOldHighlights() async throws {
        let provider = WorkspaceElasticsearchJSONBodyHighlighter()
        let controller = TextViewController(
            string: "GET /first/_search\n{\"size\":10}\nGET /second/_search\n{\"enabled\":true}", language: .json,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua),
                                                   font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [], highlightProviders: [provider]
        )
        controller.loadViewIfNeeded()
        // Query queues work; replace the source before its asynchronous result returns.
        let oldRange = NSRange(location: 0, length: (controller.text as NSString).length)
        let oldResult = Task { @MainActor in
            await withCheckedContinuation { continuation in
                provider.queryHighlightsFor(textView: controller.textView, range: oldRange) {
                    continuation.resume(returning: $0)
                }
                controller.text = "GET /中文😀/_search\n{\"name\":\"new\"}"
                provider.setUp(textView: controller.textView, codeLanguage: .json)
            }
        }
        if case .success = await oldResult.value { Issue.record("An old revision must not color the new document") }
        let updated = controller.text as NSString
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: controller.textView,
                                        range: NSRange(location: 0, length: updated.length)) {
                continuation.resume(with: $0)
            }
        }
        #expect(highlights.contains { $0.capture == .property && $0.range == updated.range(of: "\"name\"") })
        #expect(highlights.allSatisfy { NSMaxRange($0.range) <= updated.length })
    }

    @Test
    func canonicallyEquivalentConsoleReplacementUpdatesUTF16Ranges() async throws {
        let original = "GET /caf\u{00E9}\n{\"caf\u{00E9}\":1,\"next\":true}"
        let replacement = "GET /cafe\u{0301}\n{\"cafe\u{0301}\":1,\"next\":true}"
        #expect(original == replacement)
        #expect(original.utf16.count != replacement.utf16.count)
        let provider = WorkspaceElasticsearchJSONBodyHighlighter()
        let controller = makeController(original)
        provider.setUp(textView: controller.textView, codeLanguage: .json)
        _ = try await query(provider, controller: controller)
        // A programmatic replacement can be first observed by a viewport query.
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: original.utf16.count), with: replacement)
        try await compareWithFresh(provider, controller: controller, console: true)
        let highlights = try await query(provider, controller: controller)
        #expect(highlights.contains { $0.capture == .property && $0.range == (replacement as NSString).range(of: "\"next\"") })
    }

    @Test(arguments: [false, true])
    func middleEditsSplitMergeAndClearMatchFreshParsing(_ console: Bool) async throws {
        let original = console
            ? "GET /first\n{\"name\":\"中文😀\",\"size\":1e+3}\nGET /second\n{\"active\":true}\n"
            : "{\"name\":\"中文😀\",\"size\":1e+3,\"nested\":{\"active\":true}}"
        let controller = makeController(original)
        let provider = makeProvider(console: console)
        provider.setUp(textView: controller.textView, codeLanguage: .json)
        _ = try await query(provider, controller: controller)
        let operations = console
            ? [("GET /second\n", ""), ("GET /first", "POST /中文😀?pretty=true"),
               ("\"size\":1e+3", "\"size\": [\nGET /inserted\n{\"ok\":false}"),
               ("\"中文😀\"", "\"GET /fake\""), ("\nGET /second", "\n# 😀\nGET /second")]
            : [("\"name\"", "\"renamed😀\""), ("1e+3", "-2.5E-4"),
               ("\"中文😀\"", "\"\\uD83D\\uDE00\""), ("\"nested\":{", "\"nested\":["),
               ("\"active\":true", "\"active\":null,\"items\":[1,false,{}]"),
               ("\"name\":", "\"name:"), ("\"size\"", "// comment\n\"size\"")]
        for (needle, replacement) in operations + [(original, ""), (original, "{}"), (original, "\"unfinished")] {
            let range = (original as NSString).range(of: needle)
            try #require(range.location != NSNotFound)
            try await edit(provider, controller: controller, range: range, replacement: replacement)
            try await compareWithFresh(provider, controller: controller, console: console)
            try await edit(provider, controller: controller,
                           range: NSRange(location: range.location, length: replacement.utf16.count), replacement: needle)
            try await compareWithFresh(provider, controller: controller, console: console)
            #expect(controller.text == original)
        }
    }

    @Test(arguments: [false, true])
    func largeDocumentViewportsPreserveEveryBody(_ console: Bool) async throws {
        let source = (0..<180).map { index in
            (console ? "GET /events_\(index)/_search?size=\(index)\n" : "") +
                "{\"key_\(index)\":\"中文😀\\u4F60\",\"number\":\(index).25e+3,\"ok\":true}\n"
        }.joined()
        let controller = makeController(source)
        let provider = makeProvider(console: console)
        provider.setUp(textView: controller.textView, codeLanguage: .json)
        let full = try await query(provider, controller: controller)
        #expect(full.filter { $0.capture == .property }.count == 180 * 3)
        #expect(full.filter { $0.capture == .typeAlternate }.count == 180)
        if console { #expect(full.filter { $0.capture == .keyword }.count == 180) }
        // Include token interiors, UTF-16 surrogate interiors, body and request boundaries.
        for location in stride(from: 0, to: source.utf16.count, by: 149) {
            let range = NSRange(location: location, length: min(97, source.utf16.count - location))
            let partial = try await query(provider, controller: controller, range: range)
            let expected = full.compactMap { highlight -> HighlightRange? in
                let overlap = NSIntersectionRange(highlight.range, range)
                return overlap.length > 0 ? .init(range: overlap, capture: highlight.capture, modifiers: highlight.modifiers) : nil
            }
            #expect(partial == expected, "Viewport mismatch at \(range), console=\(console)")
        }
        let middle = (source as NSString).range(of: "\"key_90\"")
        try await edit(provider, controller: controller, range: middle, replacement: "\"edited😀\"")
        try await compareWithFresh(provider, controller: controller, console: console)
    }

    private func makeProvider(console: Bool) -> any HighlightProviding {
        if console { return WorkspaceElasticsearchJSONBodyHighlighter() }
        return TreeSitterClient()
    }

    private func makeController(_ source: String) -> TextViewController {
        // Keep the tested provider detached: drive its exact willEdit/applyEdit contract once.
        let controller = TextViewController(
            string: source, language: .json,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua),
                                                   font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [], highlightProviders: []
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private func query(_ provider: any HighlightProviding, controller: TextViewController,
                       range: NSRange? = nil) async throws -> [HighlightRange] {
        let requested = range ?? NSRange(location: 0, length: controller.text.utf16.count)
        let result: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: controller.textView, range: requested) {
                continuation.resume(with: $0)
            }
        }
        #expect(result.allSatisfy { $0.range.length > 0 && NSIntersectionRange($0.range, requested) == $0.range })
        #expect(zip(result, result.dropFirst()).allSatisfy { NSMaxRange($0.0.range) <= $0.1.range.location })
        return result
    }

    private func edit(_ provider: any HighlightProviding, controller: TextViewController,
                      range: NSRange, replacement: String) async throws {
        provider.willApplyEdit(textView: controller.textView, range: range)
        controller.textView.replaceCharacters(in: range, with: replacement)
        let _: IndexSet = try await withCheckedThrowingContinuation { continuation in
            provider.applyEdit(textView: controller.textView, range: range, delta: replacement.utf16.count - range.length) {
                continuation.resume(with: $0)
            }
        }
    }

    private func compareWithFresh(_ provider: any HighlightProviding, controller: TextViewController,
                                  console: Bool) async throws {
        let fresh = makeProvider(console: console)
        fresh.setUp(textView: controller.textView, codeLanguage: .json)
        let actual = try await query(provider, controller: controller)
        let expected = try await query(fresh, controller: controller)
        #expect(actual == expected, "Edit mismatch, console=\(console): \(controller.text)")
    }

    private func verify(_ marked: String, provider: any HighlightProviding,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (source, expected) = try SQLSyntaxCoverageTests.decode(marked)
        let controller = TextViewController(
            string: source, language: .json,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua),
                                                   font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [], highlightProviders: [provider]
        )
        controller.loadViewIfNeeded()
        let range = NSRange(location: 0, length: (source as NSString).length)
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: controller.textView, range: range) {
                continuation.resume(with: $0)
            }
        }
        let styles = StyledRangeContainer(documentLength: range.length, providers: [0])
        #expect(highlights.allSatisfy { $0.range.length > 0 && NSIntersectionRange($0.range, range) == $0.range })
        #expect(zip(highlights, highlights.dropFirst()).allSatisfy { NSMaxRange($0.0.range) <= $0.1.range.location })
        styles.applyHighlightResult(provider: 0, highlights: highlights, rangeToHighlight: range)
        for item in expected {
            let runs = styles.runsIn(range: item.range)
            #expect(runs.isEmpty == false, "Missing \(item.token)", sourceLocation: sourceLocation)
            let expectedCapture: CaptureName? = item.kind == "punctuation" ? .punctuation
                : item.kind == "typeAlternate" ? .typeAlternate : CaptureName.fromString(item.kind)
            try #require(expectedCapture != nil)
            for run in runs {
                #expect(run.value?.capture == expectedCapture,
                        "Expected \(item.kind) for \(item.token) in \(source)", sourceLocation: sourceLocation)
            }
            let partial: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
                provider.queryHighlightsFor(textView: controller.textView, range: item.range) {
                    continuation.resume(with: $0)
                }
            }
            #expect(partial.allSatisfy { NSIntersectionRange($0.range, item.range) == $0.range }, sourceLocation: sourceLocation)
            let partialStyles = StyledRangeContainer(documentLength: range.length, providers: [0])
            partialStyles.applyHighlightResult(provider: 0, highlights: partial, rangeToHighlight: item.range)
            for run in partialStyles.runsIn(range: item.range) {
                #expect(run.value?.capture == expectedCapture, "Partial color for \(item.token)", sourceLocation: sourceLocation)
            }
        }
    }
}
