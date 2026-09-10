import Foundation

actor WorkspaceElasticsearchConsoleWorker {
    func requests(source: String, selection: NSRange?) throws -> [ElasticsearchConsoleParsedRequest] {
        try Task.checkCancellation()
        let parser = ElasticsearchConsoleParser()
        let requests = try selection.map { try parser.requests(in: source, intersecting: $0) } ?? parser.parse(source)
        for parsed in requests {
            try Task.checkCancellation()
            try WorkspaceRequestClassifier.validate(parsed.request, policy: .writesAllowed)
            if let body = parsed.request.body {
                if WorkspaceRequestClassifier.isNDJSON(path: parsed.request.path) {
                    for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
                        try Task.checkCancellation()
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            _ = try JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed)
                        }
                    }
                } else {
                    _ = try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
                }
            }
        }
        return requests
    }

    func formatted(_ source: String) throws -> String {
        try ElasticsearchConsoleParser().formatted(source)
    }

    func previewBodies(_ requests: [WorkspaceRequest]) throws -> [String?] {
        try requests.map { request in
            try Task.checkCancellation()
            guard let body = request.body else { return nil }
            // Preview formatting never replaces the prepared request's bytes.
            // NDJSON must retain one JSON document per line.
            if WorkspaceRequestClassifier.isNDJSON(path: request.path) {
                return String(decoding: body, as: UTF8.self)
            }
            do {
                return try ElasticsearchJSONWhitespaceFormatter.format(body)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return String(decoding: body, as: UTF8.self)
            }
        }
    }

    func previewSource(_ requests: [WorkspaceRequest]) throws -> String {
        let bodies = try previewBodies(requests)
        return try zip(requests, bodies).map { request, body in
            try Task.checkCancellation()
            return "\(request.method.rawValue) \(request.path)" + (body.map { "\n" + $0 } ?? "")
        }.joined(separator: "\n\n")
    }

}

struct WorkspaceElasticsearchOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WorkspaceElasticsearchRequestNotSentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
