import AppKit
import Darwin
import Testing
@testable import CodeEditSourceEditor
@testable import QueryCraftFeature

/// Run separately with QUERYCRAFT_EDITOR_PERFORMANCE=1 to avoid contention with parallel suites.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_EDITOR_PERFORMANCE"] == "1"))
struct EditorHighlightPerformanceTests {
    private func peakMemory() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    @Test func megabyteSQLParseEditAndViewportBudget() async throws {
        let statement = "SELECT id, name, 1.25E+3 FROM users WHERE active = TRUE AND name = '中文😀';\n"
        let source = String(repeating: statement, count: 14_000)
        #expect(source.utf8.count >= 1_000_000)
        let memory = peakMemory(), clock = ContinuousClock()
        let parser = try SQLStructuralParser()
        var start = clock.now
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let parse = start.duration(to: clock.now)
        #expect(parse < .seconds(15), "Initial SQL parse: \(parse)")
        let position = source.utf16.count / 2 + 7
        let updated = (source as NSString).replacingCharacters(in: NSRange(location: position, length: 2), with: "user_id")
        start = clock.now
        _ = try await parser.parse(.init(revision: .init(2), text: updated), applying: .init(baseRevision: .init(1), replacedRange: .init(location: position, length: 2), replacement: "user_id"))
        let edit = start.duration(to: clock.now)
        #expect(edit < .seconds(5), "SQL edit: \(edit)")
        start = clock.now
        for location in [0, position, updated.utf16.count - 1024] {
            let ranges = try await parser.highlights(in: .init(location: location, length: 1024), revision: .init(2))
            #expect(!ranges.isEmpty)
            #expect(ranges.allSatisfy { $0.range.location >= location && $0.range.upperBound <= location + 1024 })
        }
        let viewport = start.duration(to: clock.now)
        #expect(viewport < .seconds(1), "Three SQL viewports: \(viewport)")
        let growth = max(0, peakMemory() - memory)
        #expect(growth < 768 * 1024 * 1024, "Peak growth: \(growth)")
        print("EDITOR_PERFORMANCE SQL bytes=\(source.utf8.count) parse=\(parse) edit=\(edit) viewports=\(viewport) peakGrowth=\(growth)")
    }

    @MainActor @Test(arguments: [false, true])
    func megabyteJSONAndConsoleViewportBudget(_ console: Bool) async throws {
        let body = "{\"name\":\"中文😀\",\"message\":\"\(String(repeating: "value ", count: 20))\",\"size\":1.25e+3,\"enabled\":true}\n"
        let source = (0..<5_500).map { (console ? "GET /events_\($0)/_search\n# comment 中文😀\n" : "") + body }.joined()
        #expect(source.utf8.count >= 1_000_000)
        let memory = peakMemory(), clock = ContinuousClock()
        let provider: any HighlightProviding = console ? WorkspaceElasticsearchJSONBodyHighlighter() : TreeSitterClient()
        var start = clock.now
        let controller = TextViewController(string: source, language: .json,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .darkAqua),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [], highlightProviders: [])
        controller.loadViewIfNeeded()
        provider.setUp(textView: controller.textView, codeLanguage: .json)
        func query(_ range: NSRange) async throws -> [HighlightRange] {
            try await withCheckedThrowingContinuation { continuation in
                provider.queryHighlightsFor(textView: controller.textView, range: range) { continuation.resume(with: $0) }
            }
        }
        _ = try await query(NSRange(location: 0, length: 1024))
        let setup = start.duration(to: clock.now)
        #expect(setup < .seconds(15), "Initial JSON/ES setup: \(setup)")
        let range = (source as NSString).range(of: "name", options: [], range: NSRange(location: source.utf16.count / 2, length: source.utf16.count / 2))
        start = clock.now
        provider.willApplyEdit(textView: controller.textView, range: range)
        controller.textView.replaceCharacters(in: range, with: "title")
        let _: IndexSet = try await withCheckedThrowingContinuation { continuation in
            provider.applyEdit(textView: controller.textView, range: range, delta: 1) { continuation.resume(with: $0) }
        }
        let edit = start.duration(to: clock.now)
        #expect(edit < .seconds(5), "JSON/ES edit: \(edit)")
        start = clock.now
        for location in [0, range.location, controller.text.utf16.count - 1024] {
            let captures = try await query(NSRange(location: location, length: 1024))
            #expect(captures.contains { $0.capture == .property })
        }
        let viewport = start.duration(to: clock.now)
        #expect(viewport < .seconds(1), "Three JSON/ES viewports: \(viewport)")
        let growth = max(0, peakMemory() - memory)
        #expect(growth < 768 * 1024 * 1024)
        print("EDITOR_PERFORMANCE console=\(console) bytes=\(source.utf8.count) setup=\(setup) edit=\(edit) viewports=\(viewport) peakGrowth=\(growth)")
    }
}
