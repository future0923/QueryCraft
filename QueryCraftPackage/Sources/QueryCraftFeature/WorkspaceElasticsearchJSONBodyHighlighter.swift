import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation

@MainActor
final class WorkspaceElasticsearchJSONBodyHighlighter: HighlightProviding {
    private struct Body {
        let source: String
        let range: NSRange
        let highlighter: TreeSitterClient
    }
    private var bodies: [Body] = []
    private var sourceSnapshot: NSString?
    private var requestHighlights: [HighlightRange] = []
    private var revision = 0

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        updateBodies(in: textView.string)
    }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor @Sendable (
            Result<IndexSet, Error>
        ) -> Void
    ) {
        updateBodies(in: textView.string)
        // Request boundaries can change outside the edited token. The editor queries
        // visible ranges; unchanged request bodies retain their parsed clients.
        completion(.success(IndexSet(integersIn: 0..<(textView.string as NSString).length)))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor @Sendable (
            Result<[HighlightRange], Error>
        ) -> Void
    ) {
        updateBodies(in: textView.string)
        let requestHighlights = requestHighlights.compactMap { highlight -> HighlightRange? in
            let intersection = NSIntersectionRange(highlight.range, range)
            guard intersection.length > 0 else { return nil }
            return .init(range: intersection, capture: highlight.capture, modifiers: highlight.modifiers)
        }
        let revision = revision
        let visibleBodies = bodies.filter { NSIntersectionRange($0.range, range).length > 0 }
        Task { @MainActor [weak self, weak textView] in
            guard let self, let textView else {
                completion(.failure(HighlightProvidingError.operationCancelled)); return
            }
            do {
                var result = requestHighlights
                for body in visibleBodies {
                    guard self.revision == revision else { throw HighlightProvidingError.operationCancelled }
                    let intersection = NSIntersectionRange(body.range, range)
                    let localRange = NSRange(location: intersection.location - body.range.location, length: intersection.length)
                    let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
                        body.highlighter.queryHighlightsFor(textView: textView, range: localRange) {
                            continuation.resume(with: $0)
                        }
                    }
                    result += highlights.map { .init(
                        range: NSRange(location: body.range.location + $0.range.location, length: $0.range.length),
                        capture: $0.capture, modifiers: $0.modifiers
                    ) }
                }
                guard self.revision == revision else { throw HighlightProvidingError.operationCancelled }
                completion(.success(result.sorted { $0.range.location < $1.range.location }))
            } catch { completion(.failure(error)) }
        }
    }

    private func updateBodies(in text: String) {
        // Swift String equality performs Unicode normalization. Highlight ranges
        // require literal UTF-16 identity, including canonically equivalent edits.
        guard sourceSnapshot?.compare(text, options: .literal) != .orderedSame else { return }
        sourceSnapshot = (text as NSString).copy() as? NSString
        revision += 1
        let source = text as NSString
        requestHighlights = Self.requestLineHighlights(in: text, intersecting: NSRange(location: 0, length: source.length))
        let comments = requestHighlights.filter { $0.capture == .comment }
        var commentIndex = 0
        bodies = Self.bodyRanges(in: text).enumerated().map { index, range in
            let fragment = NSMutableString(string: source.substring(with: range))
            // Console # comments are not JSON. Preserve UTF-16 offsets while masking
            // them, and let requestLineHighlights supply their comment styling.
            // Both lists are ordered; advance once rather than scanning every
            // comment again for every request in a large console document.
            while commentIndex < comments.count, NSMaxRange(comments[commentIndex].range) <= range.location {
                commentIndex += 1
            }
            var indexInComments = commentIndex
            while indexInComments < comments.count, comments[indexInComments].range.location < NSMaxRange(range) {
                let overlap = NSIntersectionRange(comments[indexInComments].range, range)
                if overlap.length > 0 {
                    fragment.replaceCharacters(in: NSRange(location: overlap.location - range.location, length: overlap.length),
                                               with: String(repeating: " ", count: overlap.length))
                }
                indexInComments += 1
            }
            let bodySource = fragment as String
            if index < bodies.count, (bodies[index].source as NSString).compare(bodySource, options: .literal) == .orderedSame {
                return Body(source: bodySource, range: range, highlighter: bodies[index].highlighter)
            }
            let highlighter = TreeSitterClient()
            highlighter.setUp(source: bodySource, codeLanguage: .json)
            return Body(source: bodySource, range: range, highlighter: highlighter)
        }
    }

    /// Highlighting must survive an incomplete/invalid request path elsewhere in the
    /// editor. Execution still uses ElasticsearchConsoleParser and its validation.
    private static func bodyRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var bodyStart: Int?
        var position = 0
        while position < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: position, length: 0))
            let line = source.substring(with: NSRange(location: start, length: contentsEnd - start))
                .trimmingCharacters(in: .whitespaces)
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if parts.count == 2, WorkspaceRequestMethod(rawValue: parts[0].uppercased()) != nil,
               parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                if let bodyStart, start > bodyStart { result.append(NSRange(location: bodyStart, length: start - bodyStart)) }
                bodyStart = end
            }
            guard end > position else { break }
            position = end
        }
        if let bodyStart, source.length > bodyStart {
            result.append(NSRange(location: bodyStart, length: source.length - bodyStart))
        }
        return result
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
        let trimmedRange = NSRange(location: methodStart, length: lineEnd - methodStart)
        let trimmed = source.substring(with: trimmedRange)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
            appendHighlight(range: trimmedRange, capture: .comment, intersecting: requestedRange, output: &output)
            return
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
            appendQueryHighlights(source: source,
                                  range: NSRange(location: queryRange.location, length: pathEnd - queryRange.location),
                                  requestedRange: requestedRange, output: &output)
        }
    }

    private static let numericQueryValue = try! NSRegularExpression(pattern: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#)

    private static func appendQueryHighlights(source: NSString, range: NSRange, requestedRange: NSRange,
                                               output: inout [HighlightRange]) {
        var cursor = range.location
        var isValue = false
        while cursor < NSMaxRange(range) {
            let character = source.character(at: cursor)
            if [63, 38, 61].contains(character) { // ?, &, =
                appendHighlight(range: NSRange(location: cursor, length: 1), capture: .punctuation,
                                intersecting: requestedRange, output: &output)
                isValue = character == 61
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < NSMaxRange(range), ![63, 38, 61].contains(source.character(at: cursor)) { cursor += 1 }
            let valueRange = NSRange(location: start, length: cursor - start)
            let value = source.substring(with: valueRange)
            let capture: CaptureName
            if !isValue { capture = .parameter }
            else if ["true", "false", "null"].contains(value) { capture = .boolean }
            else if numericQueryValue.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil {
                capture = .number
            } else { capture = .string }
            appendHighlight(range: valueRange, capture: capture, intersecting: requestedRange, output: &output)
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
