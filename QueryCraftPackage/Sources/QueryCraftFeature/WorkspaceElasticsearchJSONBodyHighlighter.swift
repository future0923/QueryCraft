import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation

@MainActor
final class WorkspaceElasticsearchJSONBodyHighlighter: HighlightProviding {
    private let jsonHighlighter = TreeSitterClient()
    private let parser = ElasticsearchConsoleParser()

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        jsonHighlighter.setUp(textView: textView, codeLanguage: .json)
    }

    func willApplyEdit(textView: TextView, range: NSRange) {
        jsonHighlighter.willApplyEdit(textView: textView, range: range)
    }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor @Sendable (
            Result<IndexSet, Error>
        ) -> Void
    ) {
        jsonHighlighter.applyEdit(
            textView: textView,
            range: range,
            delta: delta,
            completion: completion
        )
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor @Sendable (
            Result<[HighlightRange], Error>
        ) -> Void
    ) {
        let requestHighlights = Self.requestLineHighlights(
            in: textView.string,
            intersecting: range
        )
        let bodyRanges = (try? parser.parse(textView.string).map(\.bodyRange))
            ?? []
        jsonHighlighter.queryHighlightsFor(textView: textView, range: range) {
            result in
            completion(result.map { highlights in
                let bodyHighlights: [HighlightRange] = highlights.compactMap {
                    highlight in
                    let intersections = bodyRanges.compactMap {
                        NSIntersectionRange(highlight.range, $0).nonEmpty
                    }
                    guard let intersection = intersections.first else {
                        return nil
                    }
                    return HighlightRange(
                        range: intersection,
                        capture: highlight.capture,
                        modifiers: highlight.modifiers
                    )
                }
                return requestHighlights + bodyHighlights
            })
        }
    }

    static func requestLineHighlights(
        in text: String,
        intersecting requestedRange: NSRange
    ) -> [HighlightRange] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var highlights: [HighlightRange] = []
        var position = 0
        while position < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: position, length: 0)
            )
            appendRequestLineHighlights(
                source: source,
                lineRange: NSRange(
                    location: lineStart,
                    length: contentsEnd - lineStart
                ),
                requestedRange: requestedRange,
                output: &highlights
            )
            guard lineEnd > position else { break }
            position = lineEnd
        }
        return highlights
    }

    private static func appendRequestLineHighlights(
        source: NSString,
        lineRange: NSRange,
        requestedRange: NSRange,
        output: inout [HighlightRange]
    ) {
        let lineEnd = lineRange.location + lineRange.length
        var methodStart = lineRange.location
        while methodStart < lineEnd,
              isWhitespace(source.character(at: methodStart))
        {
            methodStart += 1
        }
        var methodEnd = methodStart
        while methodEnd < lineEnd,
              !isWhitespace(source.character(at: methodEnd))
        {
            methodEnd += 1
        }
        guard methodEnd > methodStart,
              WorkspaceRequestMethod(
                rawValue: source.substring(
                    with: NSRange(
                        location: methodStart,
                        length: methodEnd - methodStart
                    )
                ).uppercased()
              ) != nil
        else { return }

        appendHighlight(
            range: NSRange(
                location: methodStart,
                length: methodEnd - methodStart
            ),
            capture: .keyword,
            intersecting: requestedRange,
            output: &output
        )

        var pathStart = methodEnd
        while pathStart < lineEnd,
              isWhitespace(source.character(at: pathStart))
        {
            pathStart += 1
        }
        guard pathStart < lineEnd,
              source.character(at: pathStart) == 47
        else { return }
        var pathEnd = pathStart
        while pathEnd < lineEnd,
              !isWhitespace(source.character(at: pathEnd))
        {
            pathEnd += 1
        }

        let pathRange = NSRange(
            location: pathStart,
            length: pathEnd - pathStart
        )
        let queryRange = source.range(
            of: "?",
            options: [],
            range: pathRange
        )
        let pathLength = queryRange.location == NSNotFound
            ? pathRange.length
            : queryRange.location - pathRange.location
        appendHighlight(
            range: NSRange(location: pathStart, length: pathLength),
            capture: .type,
            intersecting: requestedRange,
            output: &output
        )
        if queryRange.location != NSNotFound {
            appendHighlight(
                range: NSRange(
                    location: queryRange.location,
                    length: pathEnd - queryRange.location
                ),
                capture: .number,
                intersecting: requestedRange,
                output: &output
            )
        }
    }

    private static func appendHighlight(
        range: NSRange,
        capture: CaptureName,
        intersecting requestedRange: NSRange,
        output: inout [HighlightRange]
    ) {
        guard let intersection = NSIntersectionRange(
            range,
            requestedRange
        ).nonEmpty else { return }
        output.append(HighlightRange(range: intersection, capture: capture))
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

private extension NSRange {
    var nonEmpty: NSRange? { length > 0 ? self : nil }
}
