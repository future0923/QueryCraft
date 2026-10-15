import AppKit
import CodeEditLanguages
import Testing
@testable import CodeEditSourceEditor
@testable import CodeEditTextView

@MainActor @Suite(.serialized)
struct EditorHighlightRevisionTests {
    @Test(arguments: ["x", "ghijkl", "中文😀"])
    func oldHighlightCannotRepaintReplacedText(_ replacement: String) throws {
        let view = TextView(string: "abcdef")
        let provider = DelayedProvider()
        let delegate = Recorder()
        let visible = VisibleRangeProvider(textView: view, minimapView: nil)
        visible.visibleSet = IndexSet(integersIn: view.documentRange)
        let state = HighlightProviderState(id: 0, delegate: delegate, highlightProvider: provider,
            textView: view, visibleRangeProvider: visible, language: .json)
        state.invalidate()
        let originalQuery = try #require(provider.queries.first)
        let oldRange = view.documentRange
        state.storageWillUpdate(in: oldRange)
        view.string = replacement
        visible.visibleSet = IndexSet(integersIn: view.documentRange)
        state.storageDidUpdate(range: oldRange, delta: replacement.utf16.count - oldRange.length)
        state.highlightInvalidRanges()
        #expect(provider.queries.count == 1, "Do not query while the parser is still applying an edit")
        provider.edits[0](.success(IndexSet(integersIn: view.documentRange)))
        #expect(provider.queries.count == 2)
        let currentQuery = provider.queries[1]
        currentQuery.completion(.success([.init(range: currentQuery.range, capture: .string)]))
        originalQuery.completion(.success([.init(range: originalQuery.range, capture: .keyword)]))
        #expect(delegate.results.count == 1)
        #expect(delegate.results.first?.first?.capture == .string)
        #expect(delegate.ranges == [view.documentRange])
        state.highlightInvalidRanges()
        #expect(provider.queries.count == 2)
    }

    @Test func oldEditCompletionCannotFinishANewerEdit() {
        let view = TextView(string: "abc")
        let provider = DelayedProvider()
        let delegate = Recorder()
        let visible = VisibleRangeProvider(textView: view, minimapView: nil)
        let state = HighlightProviderState(id: 0, delegate: delegate, highlightProvider: provider,
            textView: view, visibleRangeProvider: visible, language: .json)
        for text in ["abcdef", "x"] {
            let range = view.documentRange
            state.storageWillUpdate(in: range)
            view.string = text
            visible.visibleSet = IndexSet(integersIn: view.documentRange)
            state.storageDidUpdate(range: range, delta: text.utf16.count - range.length)
        }
        provider.edits[0](.success(IndexSet(integersIn: 0..<6)))
        #expect(provider.queries.isEmpty)
        provider.edits[1](.success(IndexSet(integersIn: 0..<1)))
        #expect(provider.queries.map(\.range) == [NSRange(location: 0, length: 1)])
    }

    @Test func themeInvalidationDiscardsPendingQueryWithoutLosingNewRequest() throws {
        let view = TextView(string: "abc")
        let provider = DelayedProvider()
        let delegate = Recorder()
        let visible = VisibleRangeProvider(textView: view, minimapView: nil)
        visible.visibleSet = IndexSet(integersIn: view.documentRange)
        let state = HighlightProviderState(id: 0, delegate: delegate, highlightProvider: provider,
            textView: view, visibleRangeProvider: visible, language: .json)
        state.invalidate()
        state.invalidate()
        #expect(provider.queries.count == 2)
        provider.queries[0].completion(.success([.init(range: view.documentRange, capture: .keyword)]))
        #expect(delegate.results.isEmpty)
        state.highlightInvalidRanges()
        #expect(provider.queries.count == 2, "Old callback must not clear the new pending range")
        provider.queries[1].completion(.success([.init(range: view.documentRange, capture: .string)]))
        #expect(delegate.results.count == 1)
    }

    private final class Recorder: HighlightProviderStateDelegate {
        var results: [[HighlightRange]] = []
        var ranges: [NSRange] = []
        func applyHighlightResult(provider: Int, highlights: [HighlightRange], rangeToHighlight: NSRange) {
            results.append(highlights)
            ranges.append(rangeToHighlight)
        }
    }

    private final class DelayedProvider: HighlightProviding {
        struct Query {
            let range: NSRange
            let completion: @MainActor @Sendable (Result<[HighlightRange], Error>) -> Void
        }
        var queries: [Query] = []
        var edits: [@MainActor @Sendable (Result<IndexSet, Error>) -> Void] = []
        func setUp(textView: TextView, codeLanguage: CodeLanguage) {}
        func applyEdit(textView: TextView, range: NSRange, delta: Int,
                       completion: @escaping @MainActor @Sendable (Result<IndexSet, Error>) -> Void) { edits.append(completion) }
        func queryHighlightsFor(textView: TextView, range: NSRange,
                                completion: @escaping @MainActor @Sendable (Result<[HighlightRange], Error>) -> Void) {
            queries.append(.init(range: range, completion: completion))
        }
    }
}
