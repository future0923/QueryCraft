import Foundation

struct ElasticsearchConsoleParsedRequest: Equatable, Sendable {
    let request: WorkspaceRequest
    let sourceRange: NSRange
    let bodyRange: NSRange
}

struct ElasticsearchConsoleParser: Sendable {
    func parse(_ source: String) throws -> [ElasticsearchConsoleParsedRequest] {
        let nsSource = source as NSString
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var starts: [(line: Int, method: WorkspaceRequestMethod, path: String)] = []
        for (lineIndex, lineValue) in lines.enumerated() {
            let line = lineValue.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: { $0.isWhitespace })
            else { continue }
            let methodText = String(line[..<separator]).uppercased()
            let path = line[separator...].trimmingCharacters(in: .whitespaces)
            guard let method = WorkspaceRequestMethod(rawValue: methodText),
                  path.hasPrefix("/")
            else { continue }
            starts.append((lineIndex, method, path))
        }
        guard !starts.isEmpty else {
            throw ElasticsearchConsoleParserError.missingRequestLine
        }

        var lineLocations: [Int] = []
        var location = 0
        for line in lines {
            lineLocations.append(location)
            location += (String(line) as NSString).length + 1
        }
        return try starts.enumerated().map { requestIndex, start in
            let startLocation = lineLocations[start.line]
            let endLine = requestIndex + 1 < starts.count
                ? starts[requestIndex + 1].line
                : lines.count
            let endLocation = endLine < lineLocations.count
                ? lineLocations[endLine]
                : nsSource.length
            let requestLineLength = (String(lines[start.line]) as NSString).length
            let bodyStart = min(startLocation + requestLineLength + 1, endLocation)
            let bodyRange = NSRange(
                location: bodyStart,
                length: max(0, endLocation - bodyStart)
            )
            let bodySource = nsSource.substring(with: bodyRange)
            let bodyText = bodySource.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let body: Data?
            if bodyText.isEmpty {
                body = nil
            } else if WorkspaceRequestClassifier.isNDJSON(path: start.path) {
                body = Data((bodySource.hasSuffix("\n") ? bodySource : bodySource + "\n").utf8)
            } else {
                body = Data(bodySource.utf8)
            }
            let request = WorkspaceRequest(
                method: start.method,
                path: start.path,
                body: body
            )
            try WorkspaceReadOnlyRequestValidator.validateRelativePath(request.path)
            return ElasticsearchConsoleParsedRequest(
                request: request,
                sourceRange: NSRange(
                    location: startLocation,
                    length: max(0, endLocation - startLocation)
                ),
                bodyRange: bodyRange
            )
        }
    }

    func request(
        in source: String,
        intersecting selection: NSRange
    ) throws -> ElasticsearchConsoleParsedRequest {
        try requests(in: source, intersecting: selection)[0]
    }

    func requests(
        in source: String,
        intersecting selection: NSRange
    ) throws -> [ElasticsearchConsoleParsedRequest] {
        let sourceLength = (source as NSString).length
        if selection.length > 0,
           selection.location != NSNotFound,
           selection.location <= sourceLength,
           NSMaxRange(selection) <= sourceLength
        {
            let selectedSource = (source as NSString).substring(with: selection)
            if !selectedSource.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                return try parse(selectedSource).map { parsed in
                    ElasticsearchConsoleParsedRequest(
                        request: parsed.request,
                        sourceRange: NSRange(
                            location: selection.location
                                + parsed.sourceRange.location,
                            length: parsed.sourceRange.length
                        ),
                        bodyRange: NSRange(
                            location: selection.location
                                + parsed.bodyRange.location,
                            length: parsed.bodyRange.length
                        )
                    )
                }
            }
        }
        let requests = try parse(source)
        let cursor = selection.location
        let request = requests.last(where: {
            NSLocationInRange(cursor, $0.sourceRange)
                || cursor == NSMaxRange($0.sourceRange)
        }) ?? requests[0]
        return [request]
    }

    func formatted(_ source: String) throws -> String {
        try parse(source).map { parsed in
            var output = "\(parsed.request.method.rawValue) \(parsed.request.path)"
            guard let body = parsed.request.body, !body.isEmpty else {
                return output
            }
            if WorkspaceRequestClassifier.isNDJSON(path: parsed.request.path) {
                let lines = String(decoding: body, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                let formattedLines = try lines.map { line -> String in
                    try ElasticsearchJSONWhitespaceFormatter.format(Data(line.utf8), compact: true)
                }
                output += "\n" + formattedLines.joined(separator: "\n") + "\n"
            } else {
                output += "\n" + (try ElasticsearchJSONWhitespaceFormatter.format(body))
            }
            return output
        }.joined(separator: "\n\n")
    }
}

enum ElasticsearchConsoleParserError: LocalizedError {
    case missingRequestLine

    var errorDescription: String? {
        AppCopy.current.text(
            "请输入 METHOD /path 请求行。",
            "Enter a METHOD /path request line."
        )
    }
}
